-- @description  REAPER Session Auditor
-- @author       Logan Thomas Byrne (PanamaSound)
-- @version      7.31
-- @about
--   Recording safety net for REAPER sessions, rebuilt around a
--   Collector -> Diff -> Event Queue -> Logger pipeline (the "change observer"
--   pattern: initialize a baseline snapshot of everything, monitor on a
--   schedule, diff each new snapshot against the last one, and only log/mark
--   when something actually changed).
--
--   Monitors all record-armed tracks for clips, hot input, silence, engine
--   lags, buffer underruns, disk space, storage disconnections, and arm
--   changes. Produces the human-readable master log, plus an optional JSON
--   event journal for crash recovery.
--
-- @changelog (7.1 -> 7.2)
--   - Journal flush was configured (JOURNAL_FLUSH_INTERVAL_SEC) but never
--     scheduled, so the crash-recovery journal lived in memory for the whole
--     session and only hit disk on a CRITICAL event or normal session end.
--     Now flushed on its own scheduled task.
--   - New takes recorded into an item that already existed before the record
--     pass (e.g. tape/loop-style recording into an existing item) were not
--     detected, since detection only looked for brand-new item GUIDs. Now
--     also detects take-count increases on pre-existing items, gated to the
--     actual record-pass time window.
--   - Journal writes now degrade gracefully: after repeated write failures
--     the journal disables itself for the rest of the session (noted in the
--     final log) instead of silently retrying every cycle.
--   - Added optional minimum spacing between dropped markers so simultaneous
--     anomalies don't clutter the timeline; CRITICAL events always bypass it.
--     All events are still logged regardless of marker spacing.
--   - Deduplicated the "find track by GUID" scan into one helper.
--
-- @changelog (7.2 -> 7.3)
--   - Generated Track Notes: writes a per-take summary (date, file, take #,
--     peak/RMS, max observed input, clip count) into each armed track's SWS
--     track notes after every recording pass. Only the generated section is
--     replaced -- hand-written notes above it are preserved untouched.
--     Configurable via ENABLE_GENERATED_TRACK_NOTES / GENERATED_TRACK_NOTES_HEADING.
--     Requires SWS; no-ops otherwise.
--   - Take detection moved from count-based deltas to exact take-GUID
--     identification (pre_record_take_guids). The 7.2 fallback could still
--     misidentify which take was new if multiple items were touched; GUID
--     comparison identifies the exact new take directly, and that take is
--     now what gets analyzed (previously fell back to GetActiveTake, which
--     isn't always the one just recorded).
--   - Added LogClip/LogHotInput/LogSilence/LogUnderrun/LogHardwareChange
--     wrappers around QueueEvent for the highest-traffic event families, so
--     each one's severity/source-tag/marker boilerplate lives in one place.
--   - Journal init failures now disable the journal immediately instead of
--     waiting for FlushJournal to discover it ~3 seconds later via repeated
--     failures.
--   - Region cache invalidation switched from a marker-count comparison
--     (which missed region-only changes, since CountProjectMarkers' count
--     return is markers only) to GetProjectStateChangeCount, which also
--     catches region/marker moves and renames, not just adds/removes.
--   - Added record destination change detection: flags if the project's
--     effective recording path changes mid-session.
--
-- @changelog (7.3 -> 7.31)
--   - Fixed `bad argument #1` crash in `GetSetMediaItemTakeInfo_String` caused
--     by empty take lanes returning nil.
--
-- #changelog (PREVIOUS VERSIONS)
--   - Previous versions were iterative prototypes, not publicly released, and 
--     are not documented here.
--
-- =============================================================================
-- USER CONFIGURATION
-- =============================================================================

local ENABLE_LOGGING          = true
local ENABLE_MARKERS          = true
local CONFIG_SHOW_POPUP       = false
local STUDIO_NAME             = "PANAMA SOUND"
local STUDIO_LOCATION         = "RICHMOND, CA"

-- Generated track notes -------------------------------------------------------
-- Writes a per-take summary (last recorded file, take #, peak/RMS, max
-- observed input, clip count) into each armed track's SWS track notes via
-- NF_GetSWSTrackNotes/NF_SetSWSTrackNotes. Only the generated section is
-- replaced on each recording pass -- anything the engineer wrote above the
-- heading (mic notes, performance notes, etc.) is preserved untouched.
-- Requires the SWS extension; silently does nothing if it's not installed.
local ENABLE_GENERATED_TRACK_NOTES = true
local GENERATED_TRACK_NOTES_HEADING = "GENERATED TRACK NOTES:"

-- File / directory configuration -------------------------------------------
local LOG_FILENAME_PREFIX     = "REAPER_SessionAuditor"
local LOG_SUBDIRECTORY        = ""

-- JSON event journal ----------------------------------------------------------
local ENABLE_EVENT_JOURNAL          = true
local KEEP_JOURNAL_FILE_AFTER_BUILD = false
local JOURNAL_MAX_WRITE_FAILURES    = 3   -- consecutive failures before the
                                          -- journal disables itself for the
                                          -- rest of the session

-- Marker spacing ----------------------------------------------------------
-- Minimum wall-clock seconds between dropped markers, to keep simultaneous
-- anomalies from cluttering the timeline. 0 disables spacing entirely.
-- CRITICAL-severity events always bypass this. Does not affect logging --
-- every event is still written to the log/journal regardless of spacing.
local MARKER_MIN_SPACING_SEC = 0.2

-- Scheduler intervals (seconds) -----------------------------------------------
local JOURNAL_FLUSH_INTERVAL_SEC = 1.0
local HARDWARE_SCAN_INTERVAL_SEC = 1.0
local TRACK_AUDIT_INTERVAL_SEC   = 0.5
local STORAGE_CHECK_INTERVAL     = 2.0

local POST_REC_WAIT_SEC       = 5.0
local HOT_INPUT_THRESHOLD_DB  = -3.0
local HOT_INPUT_DURATION_SEC  = 5.0
local HOT_INPUT_GRACE_SEC     = 0.50
local SILENCE_THRESHOLD_DB    = -70.0
local UNUSABLE_RMS_DB         = -10.0
local ENGINE_LAG_GAP_SEC      = 0.25
local STORAGE_WARN_GB         = 20.0
local STORAGE_CRITICAL_GB     = 10.0
local REC_SPACE_LOG_INTERVAL  = 60.0
local DEFAULT_SAMPLE_RATE     = 48000
local DEFAULT_BIT_DEPTH       = 24
local MIN_LOG_DURATION_SEC    = 10.0
local LOUDNESS_ANALYSIS_BLOCK_SIZE = 262144

local EVENT_THROTTLES_SEC = {
  CLIP          = 0.5,
  HOT_INPUT     = 30.0,
  SILENCE       = 0.0,
  ENGINE_LAG    = 10.0,
  DISK_STATUS   = REC_SPACE_LOG_INTERVAL,
  DISK_WARNING  = 0.0,
  HARDWARE      = 0.0,
  ARM_CHANGE    = 0.0,
  REGION_ENTER  = 0.0,
  TRANSPORT     = 0.0,
}

local SILENCE_THRESHOLDS = {3.0, 30.0, 120.0, 300.0}

-- =============================================================================
-- MARKER / REGION COLORS
-- =============================================================================

local function MakeColor(r, g, b) return reaper.ColorToNative(r, g, b) | 0x1000000 end

local COLOR_START       = MakeColor(  0, 220, 120)
local COLOR_CLIP        = MakeColor(220,  20,  60)
local COLOR_HOT_INPUT   = MakeColor(255, 140,   0)
local COLOR_SILENCE     = MakeColor(128, 128, 128)
local COLOR_ENGINE_LAG  = MakeColor(255,   0, 255)
local COLOR_UNDERRUN    = MakeColor(180,   0, 255)
local COLOR_DISK_WARN   = MakeColor(255, 165,   0)
local COLOR_DISK_CRIT   = MakeColor(255,   0,   0)
local COLOR_ARM_CHANGE  = MakeColor(255, 165,   0)
local COLOR_PREFLIGHT   = MakeColor(255,  80,   0)
local COLOR_SYS_ALERT   = MakeColor(255,   0, 128)
local COLOR_SR_CHANGE   = MakeColor(0,   255, 255)
local COLOR_PUNCH       = MakeColor(0,   180, 255)

-- =============================================================================
-- INTERNAL STATE & MEMORY BUFFERS
-- =============================================================================

local state = {
  previous = { tracks = {}, hardware = nil, transport = nil },
  current  = { tracks = {}, hardware = nil, transport = nil },
}

local clip_last_marker     = {}
local clip_count           = {}
local hot_start            = {}
local hot_grace_expire     = {}
local silence_start        = {}
local silence_escalation   = {}
local track_max_peak       = {}

local last_precise_time    = nil
local last_xrun_count      = nil
local has_warned_space     = false
local has_crit_space       = false
local disk_is_disconnected = false
local session_hardware_changes = 0
local session_disk_warnings    = 0
local session_underruns        = 0
local audio_engine_lost        = false
local last_proj_state_count    = -1
local last_record_path         = nil

local armed_guid_set       = {}
local rec_start_wall       = nil
local rec_start_project_pos = nil
local rec_stop_project_pos = nil
local last_play_state      = -1

local is_cooling_down      = false
local cooldown_start_time  = 0
local session_record_button_presses = 0
local total_recording_time = 0

local pre_record_item_guids = {}
local pre_record_take_guids = {}
local last_region_idx      = -1
local initial_track_states = {}
local session_metadata     = {}
local session_events       = {}
local session_summary_data = {}
local throttle_memory      = {}
local pending_journal_buffer = {}
local scheduler_tasks      = {}
local region_cache         = {}

local last_marker_wall_time     = 0
local journal_write_failures    = 0
local journal_runtime_disabled  = false

-- =============================================================================
-- UTILITY & FILE I/O
-- =============================================================================

local function SafeOpen(path, mode)
  local ok, fh = pcall(io.open, path, mode)
  if ok then return fh end
  return nil
end

local function SafeRemove(path)
  pcall(os.remove, path)
end

function GetSessionAuditorDirectory()
  local proj_path = reaper.GetProjectPath("")
  if not proj_path or proj_path == "" then return proj_path end
   
  local full_dir = proj_path
  if LOG_SUBDIRECTORY and LOG_SUBDIRECTORY ~= "" then
    local clean_sub = LOG_SUBDIRECTORY:gsub("^[/\\]+", ""):gsub("[/\\]+$", "")
    full_dir = proj_path .. "/" .. clean_sub
  end

  if reaper.RecursiveCreateDirectory then
    reaper.RecursiveCreateDirectory(full_dir, 0)
  end
  return full_dir
end

function DropMarker(wall_time, pos, name, color, bypass_spacing)
  if not ENABLE_MARKERS then return end
  if not bypass_spacing and MARKER_MIN_SPACING_SEC > 0
     and (wall_time - last_marker_wall_time) < MARKER_MIN_SPACING_SEC then
    return
  end
  reaper.AddProjectMarker2(0, false, pos, 0, name, -1, color)
  reaper.UpdateTimeline()
  last_marker_wall_time = wall_time
end

function LinearToDb(linear)
  if linear <= 0 then return -150.0 end
  return 20.0 * (math.log(linear) / math.log(10))
end

function WallTimeToHMS(seconds)
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = math.floor(seconds % 60)
  return string.format("%02d:%02d:%02d", h, m, s)
end

function ProjectPosToTimecode(pos)
  local m = math.floor(pos / 60)
  local s = pos % 60
  return string.format("%02d:%06.3f", m, s)
end

function GetProjectTimeSpan()
  if not rec_start_project_pos or not rec_stop_project_pos then return 0 end
  return math.max(0, rec_stop_project_pos - rec_start_project_pos)
end

function GlobalThrottle(event_key, scope_key, wall_time)
  local throttle_sec = EVENT_THROTTLES_SEC[event_key] or 0
  if throttle_sec <= 0 then return true end

  local key = event_key .. "::" .. tostring(scope_key or "GLOBAL")
  local last_time = throttle_memory[key]
  if last_time and (wall_time - last_time) < throttle_sec then return false end

  throttle_memory[key] = wall_time
  return true
end

function ParseTrackNotesMetadata(track)
  if not track then return nil end
  local raw_notes = ""
  if reaper.APIExists("NF_GetSWSTrackNotes") then
    raw_notes = reaper.NF_GetSWSTrackNotes(track)
  end
  if not raw_notes or raw_notes == "" then return nil end

  -- Restrict the search to before the generated section, since that
  -- section's own heading ("GENERATED TRACK NOTES:") contains the
  -- substring "NOTES:" and would otherwise get misread as engineer notes.
  local generated_start = raw_notes:find(GENERATED_TRACK_NOTES_HEADING, 1, true)
  local search_region = generated_start and raw_notes:sub(1, generated_start - 1) or raw_notes

  local notes_start = search_region:find("NOTES:")
  if notes_start then
    local extracted = search_region:sub(notes_start + 6):match("^%s*(.-)%s*$")
    if extracted and extracted ~= "" then
      return extracted:gsub("\r?\n", " ") 
    end
  end
  return nil
end

-- Builds the "GENERATED TRACK NOTES:" body for a freshly recorded take.
function BuildGeneratedTrackNotesBody(date_str, file_name, take_num, take_total, peak_str, rms_str, max_obs_str, clip_count)
  local take_str = (take_num and take_total and take_total > 0)
    and string.format("%d/%d", take_num, take_total) or "N/A"
  return table.concat({
    "Last Recorded:", date_str,
    "File:", file_name,
    "Take:", take_str,
    "Peak:", peak_str,
    "RMS:", rms_str,
    "Observed Max Input:", max_obs_str,
    "Clips:", tostring(clip_count),
  }, "\n")
end

-- Writes (or replaces) the GENERATED_TRACK_NOTES_HEADING section in a
-- track's SWS track notes, preserving anything above it untouched (mic
-- notes, performance notes, etc. that the engineer wrote by hand). No-op if
-- the feature is disabled or SWS isn't installed.
function ApplyGeneratedTrackNotes(track, body)
  if not ENABLE_GENERATED_TRACK_NOTES or not track then return end
  if not (reaper.APIExists("NF_GetSWSTrackNotes") and reaper.APIExists("NF_SetSWSTrackNotes")) then return end

  local ok, raw_notes = pcall(reaper.NF_GetSWSTrackNotes, track)
  if not ok or not raw_notes then raw_notes = "" end

  local heading_start = raw_notes:find(GENERATED_TRACK_NOTES_HEADING, 1, true)
  local preserved = (heading_start and raw_notes:sub(1, heading_start - 1) or raw_notes):gsub("%s+$", "")

  local new_notes = (preserved ~= "")
    and (preserved .. "\n\n" .. GENERATED_TRACK_NOTES_HEADING .. "\n" .. body)
    or (GENERATED_TRACK_NOTES_HEADING .. "\n" .. body)

  pcall(reaper.NF_SetSWSTrackNotes, track, new_notes)
end

local function RebuildRegionCache()
  region_cache = {}
  local _, m, r = reaper.CountProjectMarkers(0)
  for i=0,m+r-1 do
    local rv,isrgn,s,e,name,idx = reaper.EnumProjectMarkers3(0,i)
    if rv and isrgn then
      table.insert(region_cache, {s=s, e=e, name=name, idx=idx})
    end
  end
end

function GetRegionContextAtPos(pos)
  for _, rgn in ipairs(region_cache) do
    if pos >= rgn.s and pos <= rgn.e then
      return rgn.idx, (rgn.name ~= "" and rgn.name or "Unnamed Region")
    end
  end
  return -1, ""
end

function GetDeviceNameFromIni()
  local ini_path = reaper.get_ini_file()
  local f = SafeOpen(ini_path, "r")
  if not f then return "Unknown Device" end
  local dev_name = "Default System Mapping"
  for line in f:lines() do
    if line:match("^coreaudioindevnew=") then dev_name = line:match("^coreaudioindevnew=(.*)"); break
    elseif line:match("^coreaudiooutdevnew=") then dev_name = line:match("^coreaudiooutdevnew=(.*)"); break
    elseif line:match("^coreaudio_dev=") then dev_name = line:match("^coreaudio_dev=(.*)"); break
    elseif line:match("^asio_driver=") then dev_name = line:match("^asio_driver=(.*)"); break
    elseif line:match("^wasapi_indev=") then dev_name = line:match("^wasapi_indev=(.*)"); break
    end
  end
  f:close()
  return dev_name:gsub("\r", "")
end

function GetProjectAudioParams()
  local sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
  if not sr or sr == 0 then sr = DEFAULT_SAMPLE_RATE end
  local bd = reaper.GetSetProjectInfo(0, "RENDER_DEPTH", 0, false)
  if not bd or bd == 0 then bd = DEFAULT_BIT_DEPTH end
  return math.floor(sr), math.floor(bd)
end

-- =============================================================================
-- JSON ENCODING
-- =============================================================================

local JSON_ESCAPES = {['\\'] = '\\\\', ['"'] = '\\"', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
function JsonEscapeString(s) return (tostring(s):gsub('[\\"\n\r\t]', JSON_ESCAPES)) end

function JsonEncodeValue(v)
  local t = type(v)
  if t == "string" then return '"' .. JsonEscapeString(v) .. '"'
  elseif t == "number" then return (v ~= v or v == math.huge or v == -math.huge) and "0" or tostring(v)
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "table" then
    if #v > 0 then
      local parts = {}
      for _, item in ipairs(v) do table.insert(parts, JsonEncodeValue(item)) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, val in pairs(v) do
        table.insert(parts, '"' .. JsonEscapeString(k) .. '":' .. JsonEncodeValue(val))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

function JsonEncodeEvent(ev)
  return JsonEncodeValue({ t = ev.wall_time, pos = ev.pos, sev = ev.severity, trk = ev.track, src = ev.source, msg = ev.msg })
end

-- =============================================================================
-- EVENT QUEUE / JOURNAL / LOGGER
-- =============================================================================

function FlushJournal()
  if not ENABLE_LOGGING or not ENABLE_EVENT_JOURNAL or journal_runtime_disabled then return end
  if #pending_journal_buffer == 0 then return end

  local f = SafeOpen(session_metadata.journal_path, "a")
  if not f then
    journal_write_failures = journal_write_failures + 1
    if journal_write_failures >= JOURNAL_MAX_WRITE_FAILURES then
      journal_runtime_disabled = true
      pending_journal_buffer = {}
      AppendRawEvent(reaper.time_precise(), reaper.GetPlayPosition(), "EVENT",
        string.format("Event journal disabled after %d consecutive write failures (crash recovery degraded for rest of session).", journal_write_failures),
        nil, "SYS", "--")
    end
    return
  end

  journal_write_failures = 0
  for _, ev in ipairs(pending_journal_buffer) do f:write(JsonEncodeEvent(ev) .. "\n") end
  f:close()
  pending_journal_buffer = {}
end

function AppendRawEvent(wall_time, pos, severity, msg, region_name, source, track_num)
  if not ENABLE_LOGGING then return end
  local ev = { 
      wall_time = wall_time, pos = pos, severity = severity or "EVENT", 
      msg = msg, region = region_name or "", source = source or "SYS", track = track_num or "--" 
  }
  table.insert(session_events, ev)
  if ENABLE_EVENT_JOURNAL and not journal_runtime_disabled then
    table.insert(pending_journal_buffer, ev)
  end
  if severity == "CRITICAL" then FlushJournal() end
end

function QueueEvent(wall_time, project_pos, event_str, severity, throttle_key, throttle_scope, marker_text, marker_color, source_tag, track_num)
  if not ENABLE_LOGGING then return end
  if throttle_key and not GlobalThrottle(throttle_key, throttle_scope, wall_time) then return end

  if marker_text and ENABLE_MARKERS then
    DropMarker(wall_time, project_pos, marker_text, marker_color or COLOR_SYS_ALERT, severity == "CRITICAL")
  end
  local idx, name = GetRegionContextAtPos(project_pos)
  AppendRawEvent(wall_time, project_pos, severity, event_str, (idx ~= -1) and name or "", source_tag, track_num)
end

-- Named wrappers for the most frequently-logged event families. Centralizes
-- the severity/source-tag/marker-color boilerplate for each so call sites
-- only pass the data that actually varies, instead of repeating the full
-- QueueEvent argument list at every detection point.
function LogClip(wall_time, project_pos, track_num, is_master_fallback)
  QueueEvent(wall_time, project_pos, "Clipped", "ANOMALY", nil, nil,
    is_master_fallback and "[MASTER CLIP]" or string.format("[CLIP] Trk %d", track_num),
    COLOR_CLIP, "AUD", is_master_fallback and "--" or track_num)
end

function LogHotInput(wall_time, project_pos, track_num, peak_db)
  QueueEvent(wall_time, project_pos, string.format("Sustained hot input at %.1f dBFS", peak_db),
    "ANOMALY", nil, nil, string.format("[HOT] (%.1f dB)", peak_db), COLOR_HOT_INPUT, "AUD", track_num)
end

function LogSilence(wall_time, project_pos, track_num, guid, stage, time_label)
  QueueEvent(wall_time, project_pos, string.format("No signal for %s", time_label), "ANOMALY", "SILENCE",
    guid .. ":" .. tostring(stage), string.format("[SILENCE] (%s)", time_label), COLOR_SILENCE, "AUD", track_num)
end

function LogUnderrun(wall_time, project_pos, new_xruns)
  QueueEvent(wall_time, project_pos, string.format("Buffer underrun (x%d)", new_xruns), "ANOMALY", nil, nil,
    string.format("[UNDERRUN] x%d", new_xruns), COLOR_UNDERRUN, "ENG", "--")
end

function LogHardwareChange(wall_time, project_pos, throttle_scope, msg, marker_text, marker_color)
  QueueEvent(wall_time, project_pos, msg, "ANOMALY", "HARDWARE", throttle_scope, marker_text, marker_color, "HW", "--")
end

function InitJournal()
  if not ENABLE_LOGGING or not ENABLE_EVENT_JOURNAL then return end
  local f = SafeOpen(session_metadata.journal_path, "w")
  if not f then
    journal_runtime_disabled = true
    AppendRawEvent(reaper.time_precise(), reaper.GetPlayPosition(), "EVENT",
      "Event journal could not be created (crash recovery disabled for this session).",
      nil, "SYS", "--")
    return
  end
  f:write(JsonEncodeValue({
    meta = true, studio = session_metadata.studio_name, project = session_metadata.proj_name,
    started = session_metadata.start_time, rec_start_wall = rec_start_wall
  }) .. "\n")
  f:close()
end

function FinalizeJournal()
  if not ENABLE_LOGGING or not ENABLE_EVENT_JOURNAL then return end
  FlushJournal()
  if not KEEP_JOURNAL_FILE_AFTER_BUILD then SafeRemove(session_metadata.journal_path) end
end

-- =============================================================================
-- SCHEDULER
-- =============================================================================

function RegisterTask(name, interval, fn)
  scheduler_tasks[name] = { interval = interval, last_run = 0, fn = fn }
end

function RunScheduledTasks(wall_time, project_pos, ctx)
  for _, task in pairs(scheduler_tasks) do
    if (wall_time - task.last_run) >= task.interval then
      task.last_run = wall_time
      task.fn(wall_time, project_pos, ctx)
    end
  end
end

-- =============================================================================
-- ITEM BOUNDS & LOUDNESS
-- =============================================================================

function CachePreRecordItems(tracks)
  for _, track in ipairs(tracks) do
     local count = reaper.CountTrackMediaItems(track)
     for i = 0, count - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local retval, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
        if retval then
          pre_record_item_guids[guid] = true
          local take_guids = {}
          for k = 0, reaper.CountTakes(item) - 1 do
            local take = reaper.GetMediaItemTake(item, k)
            if take then
              local _, tguid = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
              if tguid ~= "" then take_guids[tguid] = true end
            end
          end
          pre_record_take_guids[guid] = take_guids
        end
     end
  end
end

-- Finds the item+take this track recorded into during the most recent pass.
-- Primary case: a brand-new item (most recording modes create one per pass).
-- Fallback case: a take added to an item that already existed before
-- recording (e.g. tape/loop recording into an existing item region) --
-- caught by comparing take GUIDs (not just counts), so the exact new take
-- is identified even if it isn't REAPER's current "active" take. Gated to
-- the actual record-pass window in case more than one pre-existing item
-- on the track gained a take.
function FindNewlyRecordedTake(track, rec_start_pos, rec_end_pos)
  local found_new_item = nil
  for j = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
    local item = reaper.GetTrackMediaItem(track, j)
    local _, iguid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
    if not pre_record_item_guids[iguid] then
      if not found_new_item then found_new_item = item end
    end
  end
  if found_new_item then
    return found_new_item, reaper.GetActiveTake(found_new_item)
  end

  for j = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
    local item = reaper.GetTrackMediaItem(track, j)
    local _, iguid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
    local prior_take_guids = pre_record_take_guids[iguid]
    if prior_take_guids then
      local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_end = item_pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      if item_end >= (rec_start_pos or 0) and item_pos <= (rec_end_pos or item_end) then
        for k = 0, reaper.CountTakes(item) - 1 do
          local take = reaper.GetMediaItemTake(item, k)
          if take then
            local _, tguid = reaper.GetSetMediaItemTakeInfo_String(take, "GUID", "", false)
            if tguid ~= "" and not prior_take_guids[tguid] then
              return item, take
            end
          end
        end
      end
    end
  end
  return nil, nil
end

local function AnalyzeTakeLoudness(take)
    if not take then return -144, -144 end
    local accessor = reaper.CreateTakeAudioAccessor(take)
    if not accessor then return -144, -144 end
 
    local source = reaper.GetMediaItemTake_Source(take)
    local samplerate = reaper.GetMediaSourceSampleRate(source)
    if samplerate == 0 then samplerate = DEFAULT_SAMPLE_RATE end
    local num_channels = reaper.GetMediaSourceNumChannels(source)
    local start_time = reaper.GetAudioAccessorStartTime(accessor)
    local end_time = reaper.GetAudioAccessorEndTime(accessor)
    if end_time - start_time <= 0 then reaper.DestroyAudioAccessor(accessor) return -144, -144 end

    local block_size = LOUDNESS_ANALYSIS_BLOCK_SIZE
    local buffer = reaper.new_array(block_size * num_channels)
    local max_peak, sum_squares, total_samples, pos = 0, 0, 0, start_time

    while pos < end_time do
        local samples_to_read = math.floor((end_time - pos) * samplerate)
        if samples_to_read > block_size then samples_to_read = block_size end
        if samples_to_read <= 0 then break end
        if reaper.GetAudioAccessorSamples(accessor, samplerate, num_channels, pos, samples_to_read, buffer) <= 0 then break end

        for i = 1, samples_to_read * num_channels do
            local val = math.abs(buffer[i])
            if val > max_peak then max_peak = val end
            sum_squares = sum_squares + (val * val)
        end
        total_samples = total_samples + (samples_to_read * num_channels)
        pos = pos + (samples_to_read / samplerate)
    end
    reaper.DestroyAudioAccessor(accessor)

    local peak_db = (max_peak > 0) and (20 * math.log(max_peak, 10)) or -144
    local rms_db = (total_samples > 0 and sum_squares > 0) and (20 * math.log(math.sqrt(sum_squares / total_samples), 10)) or -144
    return peak_db, rms_db
end

-- =============================================================================
-- HARDWARE & FX SNAPSHOTTING
-- =============================================================================

function GetInputChannelName(track)
  local input_idx = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_RECINPUT"))
  if input_idx < 0 then return "None" end
  if input_idx & 1024 == 1024 then
    local midi_chan, midi_dev = input_idx & 31, (input_idx >> 5) & 31
    return string.format("MIDI (Dev %d, Ch %s)", midi_dev, (midi_chan == 0) and "All" or tostring(midi_chan))
  end
  local is_stereo = (input_idx & 512 == 512)
  local channel_num = input_idx & 127
  if is_stereo then
    return string.format("Stereo [%s / %s]", reaper.GetInputChannelName(channel_num) or tostring(channel_num+1), reaper.GetInputChannelName(channel_num+1) or tostring(channel_num+2))
  end
  return reaper.GetInputChannelName(channel_num) or string.format("Input %d", channel_num + 1)
end

function GetInputMonitorMode(track)
  local mode = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_RECMON"))
  if mode == 0 then return "Off" elseif mode == 1 then return "Normal" elseif mode == 2 then return "Auto" end
  return "Unknown"
end

function GetRecordModeName(mode)
  if mode == 0 then return "Input"
  elseif mode == 1 then return "Output (Stereo)"
  elseif mode == 2 then return "None (Monitor only)"
  elseif mode == 3 then return "Output (Mono)"
  elseif mode == 4 then return "MIDI (Overdub)"
  elseif mode == 5 then return "MIDI (Replace)"
  elseif mode == 6 then return "MIDI (Touch-Replace)"
  elseif mode == 7 then return "MIDI (Latch-Replace)"
  else return "Unknown" end
end

function GetFXChainState(track, is_input)
  local count = is_input and reaper.TrackFX_GetRecCount(track) or reaper.TrackFX_GetCount(track)
  local chain = {}
  for i = 0, count - 1 do
    local fx_idx = is_input and (i | 0x1000000) or i
    local _, name = reaper.TrackFX_GetFXName(track, fx_idx, "")
    name = name:gsub("^%s*(.-)%s*%b()$", "%1"):gsub("^VST%d*:%s*", ""):gsub("^AU:%s*", "")
    table.insert(chain, { guid = reaper.TrackFX_GetFXGUID(track, fx_idx), name = name, enabled = reaper.TrackFX_GetEnabled(track, fx_idx), index = i })
  end
  return chain
end

function CaptureTrackStateSnapshot(track)
  local _, guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
  return { guid = guid, input = GetInputChannelName(track), monitor = GetInputMonitorMode(track), recmode = GetRecordModeName(math.floor(reaper.GetMediaTrackInfo_Value(track, "I_RECMODE"))) }
end

-- =============================================================================
-- COLLECTORS & DIFF
-- =============================================================================

function CollectTrackPeakState(track)
  local max_peak = math.max(reaper.Track_GetPeakInfo(track, 0), reaper.Track_GetPeakInfo(track, 1))
  return { max_peak = max_peak, max_db = LinearToDb(max_peak) }
end

function CollectTrackParamState(track)
  local _, name = reaper.GetTrackName(track)
  return {
    name = name,
    vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL"),
    pan = reaper.GetMediaTrackInfo_Value(track, "D_PAN"),
    phase = reaper.GetMediaTrackInfo_Value(track, "B_PHASE"),
    mute = reaper.GetMediaTrackInfo_Value(track, "B_MUTE"),
    solo = reaper.GetMediaTrackInfo_Value(track, "I_SOLO"),
    recinput = reaper.GetMediaTrackInfo_Value(track, "I_RECINPUT"),
    recmode = reaper.GetMediaTrackInfo_Value(track, "I_RECMODE"),
    recmon = reaper.GetMediaTrackInfo_Value(track, "I_RECMON"),
    fx = GetFXChainState(track, false),
    input_fx = GetFXChainState(track, true)
  }
end

function CollectHardwareState()
  local sr = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
  local _, block_size = reaper.GetAudioDeviceInfo("BSIZE", "")
  return { sample_rate = sr, device = reaper.GetAudioDeviceInfo("PRODUCT", ""), block_size = block_size, engine_mode = reaper.GetAudioDeviceInfo("MODE", "") }
end

function CollectTransportState()
  local r_start, r_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  return { repeat_on = reaper.GetToggleCommandState(1068) == 1, loop_start = r_start, loop_end = r_end }
end

function BuildGuidSet(tracks)
  local set = {}
  for _, track in ipairs(tracks) do
    local _, guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
    local _, name = reaper.GetTrackName(track)
    set[guid] = name
  end
  return set
end

function FindTrackByGUID(guid)
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    local _, tg = reaper.GetSetMediaTrackInfo_String(t, "GUID", "", false)
    if tg == guid then return t end
  end
  return nil
end

function ProcessPeakChanges(wall_time, project_pos, track, is_master_fallback, peak)
  local _, guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
  local track_num = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))

  if not clip_last_marker[guid]   then clip_last_marker[guid]   = 0 end
  if not clip_count[guid]         then clip_count[guid]         = 0 end
  if not hot_start[guid]          then hot_start[guid]          = 0 end
  if not silence_start[guid]      then silence_start[guid]      = 0 end
  if not silence_escalation[guid] then silence_escalation[guid] = 0 end

  if not track_max_peak[guid] or peak.max_db > track_max_peak[guid] then track_max_peak[guid] = peak.max_db end

  if peak.max_peak >= 1.0 and GlobalThrottle("CLIP", guid, wall_time) then
    LogClip(wall_time, project_pos, track_num, is_master_fallback)
    clip_last_marker[guid] = wall_time
    clip_count[guid] = clip_count[guid] + 1
  end

  if not is_master_fallback then
    if peak.max_db >= HOT_INPUT_THRESHOLD_DB and peak.max_peak < 1.0 then
      if hot_start[guid] == 0 then hot_start[guid] = wall_time end
      if (wall_time - hot_start[guid]) >= HOT_INPUT_DURATION_SEC and GlobalThrottle("HOT_INPUT", guid, wall_time) then
        LogHotInput(wall_time, project_pos, track_num, peak.max_db)
      end
    else
      hot_grace_expire[guid] = hot_grace_expire[guid] or wall_time + HOT_INPUT_GRACE_SEC
      if wall_time >= hot_grace_expire[guid] then hot_start[guid] = 0 end
    end

    if peak.max_db < SILENCE_THRESHOLD_DB then
      if silence_start[guid] == 0 then silence_start[guid] = wall_time end
      local silent_duration, current_stage = wall_time - silence_start[guid], silence_escalation[guid]
      if current_stage < #SILENCE_THRESHOLDS and silent_duration >= SILENCE_THRESHOLDS[current_stage + 1] then
        silence_escalation[guid] = current_stage + 1
        local time_label = SILENCE_THRESHOLDS[current_stage + 1] .. "s"
        LogSilence(wall_time, project_pos, track_num, guid, current_stage + 1, time_label)
      end
    else
      if silence_start[guid] ~= 0 and silence_escalation[guid] > 0 then
        QueueEvent(wall_time, project_pos, string.format("Signal returned after %.0fs", wall_time - silence_start[guid]), "EVENT", nil, nil, nil, nil, "AUD", track_num)
      end
      silence_start[guid], silence_escalation[guid] = 0, 0
    end
  end
end

function DiffFXChain(prev_chain, curr_chain, prefix)
  local changes, prev_map, curr_map = {}, {}, {}
  if not prev_chain or not curr_chain then return changes end
  for _, fx in ipairs(prev_chain) do prev_map[fx.guid] = fx end
  for _, fx in ipairs(curr_chain) do curr_map[fx.guid] = fx end

  for _, p_fx in ipairs(prev_chain) do if not curr_map[p_fx.guid] then table.insert(changes, string.format("FX '%s' removed", p_fx.name)) end end
  for _, c_fx in ipairs(curr_chain) do
    local p_fx = prev_map[c_fx.guid]
    if not p_fx then table.insert(changes, string.format("FX '%s' inserted", c_fx.name))
    else
      if c_fx.enabled ~= p_fx.enabled then table.insert(changes, string.format("FX '%s' %s", c_fx.name, c_fx.enabled and "enabled" or "bypassed")) end
      if c_fx.index ~= p_fx.index then table.insert(changes, string.format("FX '%s' reordered", c_fx.name)) end
    end
  end
  return changes
end

function DiffTrackParams(track, track_num, prev, curr)
  local changes = {}
  if not prev then return changes end

  if curr.name ~= prev.name then table.insert(changes, string.format("Renamed: '%s' → '%s'", prev.name, curr.name)) end
  if math.abs(curr.vol - prev.vol) > 0.005 then table.insert(changes, string.format("Fader → %.1f dB", LinearToDb(curr.vol))) end
  if math.abs(curr.pan - prev.pan) > 0.01 then
    local pan_str = curr.pan == 0 and "Center" or (curr.pan < 0 and string.format("%.0f%%L", math.abs(curr.pan) * 100) or string.format("%.0f%%R", curr.pan * 100))
    table.insert(changes, string.format("Pan → %s", pan_str))
  end
  if curr.phase ~= prev.phase then table.insert(changes, string.format("Polarity → %s", (curr.phase > 0) and "INVERTED (ø)" or "NORMAL")) end
  if curr.mute ~= prev.mute then table.insert(changes, string.format("%s", (curr.mute > 0) and "Muted" or "Unmuted")) end
  if curr.solo ~= prev.solo then table.insert(changes, string.format("%s", (curr.solo > 0) and "Soloed" or "Unsoloed")) end
  if curr.recinput ~= prev.recinput then table.insert(changes, string.format("Input → %s", GetInputChannelName(track))) end
  if curr.recmon ~= prev.recmon then table.insert(changes, string.format("Monitor → %s", GetInputMonitorMode(track))) end
  if curr.recmode ~= prev.recmode then table.insert(changes, string.format("RecMode → %s", GetRecordModeName(curr.recmode))) end

  for _, c in ipairs(DiffFXChain(prev.fx, curr.fx, "Insert")) do table.insert(changes, c) end
  for _, c in ipairs(DiffFXChain(prev.input_fx, curr.input_fx, "Input")) do table.insert(changes, c) end
  return changes
end

function RunTrackAuditTask(wall_time, project_pos, ctx)
  if ctx.is_master_fallback then return end

  local current_set = BuildGuidSet(ctx.target_tracks)
  local current_armed_count = 0
  for _ in pairs(current_set) do current_armed_count = current_armed_count + 1 end

  -- Safety Check: Disarmed all tracks while recording
  if current_armed_count == 0 and reaper.GetPlayState() == 5 then
    local prev_count = 0
    for _ in pairs(armed_guid_set) do prev_count = prev_count + 1 end
    if prev_count > 0 then QueueEvent(wall_time, project_pos, "All tracks disarmed during recording pass!", "CRITICAL", nil, nil, "[CRIT: 0 ARMED]", COLOR_DISK_CRIT, "SYS", "--") end
  end

  for guid, name in pairs(current_set) do
    if not armed_guid_set[guid] then
      local track_num = "--"
      local t = FindTrackByGUID(guid)
      if t then
        track_num = math.floor(reaper.GetMediaTrackInfo_Value(t, "IP_TRACKNUMBER"))
        initial_track_states[guid] = CaptureTrackStateSnapshot(t)
        state.previous.tracks[guid] = CollectTrackParamState(t)
      end
      QueueEvent(wall_time, project_pos, "Armed", "EVENT", "ARM_CHANGE", guid, "[ARM] +", COLOR_ARM_CHANGE, "TRK", track_num)
    end
  end

  for guid, name in pairs(armed_guid_set) do
    if not current_set[guid] then QueueEvent(wall_time, project_pos, "Disarmed", "EVENT", "ARM_CHANGE", guid, "[ARM] -", COLOR_ARM_CHANGE, "TRK", "--") end
  end

  armed_guid_set = current_set

  for _, track in ipairs(ctx.target_tracks) do
    local _, guid = reaper.GetSetMediaTrackInfo_String(track, "GUID", "", false)
    local track_num = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
    local curr = CollectTrackParamState(track)
    for _, msg in ipairs(DiffTrackParams(track, track_num, state.previous.tracks[guid], curr)) do
      QueueEvent(wall_time, project_pos, msg, "EVENT", nil, nil, nil, nil, "TRK", track_num)
    end
    state.previous.tracks[guid] = curr
  end

  -- Transport State Audit
  local curr_trans = CollectTransportState()
  if state.previous.transport then
      if curr_trans.repeat_on ~= state.previous.transport.repeat_on then
          QueueEvent(wall_time, project_pos, "Loop mode " .. (curr_trans.repeat_on and "enabled" or "disabled"), "EVENT", nil, nil, nil, nil, "SYS", "--")
      end
      if curr_trans.loop_start ~= state.previous.transport.loop_start or curr_trans.loop_end ~= state.previous.transport.loop_end then
          QueueEvent(wall_time, project_pos, string.format("Time selection changed (%.1fs - %.1fs)", curr_trans.loop_start, curr_trans.loop_end), "EVENT", nil, nil, nil, nil, "SYS", "--")
      end
  end
  state.previous.transport = curr_trans
end

function RunHardwareScanTask(wall_time, project_pos, ctx)
  local curr = CollectHardwareState()
  local prev = state.previous.hardware

  if prev then
    if curr.sample_rate ~= prev.sample_rate then
      LogHardwareChange(wall_time, project_pos, "sample_rate",
        string.format("SR Chg. %dHz -> %dHz", math.floor(prev.sample_rate), math.floor(curr.sample_rate)),
        "SR Change", COLOR_SR_CHANGE)
      session_hardware_changes = session_hardware_changes + 1
    end
    if curr.device ~= prev.device and curr.device ~= "" and prev.device ~= "" then
      LogHardwareChange(wall_time, project_pos, "audio_device",
        string.format("Audio driver changed: '%s' -> '%s'", prev.device, curr.device),
        "Audio Device Reset", COLOR_SYS_ALERT)
      session_hardware_changes = session_hardware_changes + 1
    end
    if curr.block_size ~= prev.block_size and curr.block_size ~= "" and prev.block_size ~= "" then
      LogHardwareChange(wall_time, project_pos, "block_size",
        string.format("Audio block size changed: %s -> %s", prev.block_size, curr.block_size),
        nil, nil)
      session_hardware_changes = session_hardware_changes + 1
    end
  end

  -- Record destination change: the effective path new recordings land in
  -- (project dir, or the project's RECORD_PATH override resolved against
  -- it). Worth flagging loudly -- silently recording to a different drive
  -- mid-session is the kind of thing that can cost an entire session.
  local curr_record_path = reaper.GetProjectPathEx(0, "")
  if last_record_path == nil then
    last_record_path = curr_record_path
  elseif curr_record_path ~= "" and curr_record_path ~= last_record_path then
    LogHardwareChange(wall_time, project_pos, "record_path",
      string.format("Record destination changed: '%s' -> '%s'", last_record_path, curr_record_path),
      "[REC PATH CHANGED]", COLOR_SYS_ALERT)
    last_record_path = curr_record_path
  end

  if (not curr.engine_mode or curr.engine_mode == "") and not audio_engine_lost then
    QueueEvent(wall_time, project_pos, "Audio engine stopped unexpectedly.", "CRITICAL", nil, nil, "CRITICAL: Lost Audio Engine", COLOR_DISK_CRIT, "ENG", "--")
    audio_engine_lost, session_hardware_changes = true, session_hardware_changes + 1
  elseif curr.engine_mode and curr.engine_mode ~= "" and audio_engine_lost then
    QueueEvent(wall_time, project_pos, "Audio engine reestablished.", "EVENT", nil, nil, nil, nil, "ENG", "--")
    audio_engine_lost = false
  end
  state.previous.hardware = curr
end

function RunDiskScanTask(wall_time, project_pos, ctx)
  local free_mb = reaper.GetFreeDiskSpaceForRecordPath(0, 0)
  
  if not free_mb then
    if not disk_is_disconnected then
      QueueEvent(wall_time, project_pos, "Disk disconnected: target record drive disappeared.", "CRITICAL", nil, nil, "[CRITICAL: DISK DISCONNECTED]", COLOR_DISK_CRIT, "DSK", "--")
      disk_is_disconnected, session_disk_warnings = true, session_disk_warnings + 1
    end
    return
  end
  disk_is_disconnected = false

  local free_gb = free_mb / 1024.0
  if free_gb < STORAGE_CRITICAL_GB and not has_crit_space then
    QueueEvent(wall_time, project_pos, string.format("Disk space critical: %.2f GB remaining", free_gb), "CRITICAL", "DISK_WARNING", "critical", string.format("[DISK CRITICAL] %.1f GB", free_gb), COLOR_DISK_CRIT, "DSK", "--")
    has_crit_space, has_warned_space, session_disk_warnings = true, true, session_disk_warnings + 1
  elseif free_gb < STORAGE_WARN_GB and not has_warned_space then
    QueueEvent(wall_time, project_pos, string.format("Disk space warning: %.2f GB remaining", free_gb), "ANOMALY", "DISK_WARNING", "warning", string.format("[DISK LOW] %.1f GB", free_gb), COLOR_DISK_WARN, "DSK", "--")
    has_warned_space, session_disk_warnings = true, session_disk_warnings + 1
  end
end

-- =============================================================================
-- METADATA & FINAL ASSEMBLY
-- =============================================================================

function PreFlightChecks()
    local dir = GetSessionAuditorDirectory()
    local testfile = dir .. "/.auditor_write_test"
    local f = SafeOpen(testfile, "w")
    if f then f:close(); SafeRemove(testfile) else
        reaper.MB("WARNING: Target directory is not writable. Logs cannot be saved.", "Session Auditor", 0)
    end

    local path_lower = dir:lower()
    local is_sys = false
    if reaper.GetOS():match("Win") then
        local sysdrv = (os.getenv("SystemDrive") or "c:"):lower()
        is_sys = (path_lower:sub(1, #sysdrv) == sysdrv)
    else
        is_sys = path_lower:match("^/users/") or path_lower:match("^/system/") or path_lower:match("^/private/") or path_lower == "/"
    end
    if is_sys then session_metadata.sys_warn = "[WARNING: Recording directly to OS Volume]" end

    local sr_proj = reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false)
    local sr_hw = tonumber(reaper.GetAudioDeviceInfo("SRATE", "") or "0")
    if sr_hw and sr_hw > 0 and sr_proj > 0 and sr_hw ~= sr_proj then
        session_metadata.sr_warn = string.format("[CRITICAL: Project SR %d does not match Device SR %d]", sr_proj, sr_hw)
    end
    
    local i = 0
    local found_crash = false
    while true do
        local file = reaper.EnumerateFiles(dir, i)
        if not file then break end
        if file:match("^" .. LOG_FILENAME_PREFIX .. ".*%.json$") then found_crash = true end
        i = i + 1
    end
    if found_crash then session_metadata.crash_warn = "[NOTICE: Unfinalized JSON journals detected in directory (crash recovery possible)]" end
end

function GatherSessionMetadata()
  session_metadata.proj_path = reaper.GetProjectPath("")
  session_metadata.proj_name = reaper.GetProjectName(0, "")
  if session_metadata.proj_name == "" then session_metadata.proj_name = "(unsaved)" end

  local compact_date = os.date("%y%m%d_%H%M")
  local output_dir = GetSessionAuditorDirectory()

  session_metadata.output_dir       = output_dir
  session_metadata.log_filename     = string.format("%s_%s.txt", LOG_FILENAME_PREFIX, compact_date)
  session_metadata.log_path         = output_dir .. "/" .. session_metadata.log_filename
  session_metadata.journal_filename = string.format("%s_%s.json", LOG_FILENAME_PREFIX, compact_date)
  session_metadata.journal_path     = output_dir .. "/" .. session_metadata.journal_filename

  session_metadata.start_time = os.date("%Y-%m-%d %H:%M:%S")
  session_metadata.studio_name = STUDIO_NAME
  session_metadata.studio_location = STUDIO_LOCATION
  session_metadata.os_string = reaper.GetOS()

  local free_mb = reaper.GetFreeDiskSpaceForRecordPath(0, 0)
  session_metadata.free_gb_str = free_mb and string.format("%.2f GB", free_mb / 1024.0) or "UNKNOWN"
  session_metadata.sr, session_metadata.bd = GetProjectAudioParams()
  session_metadata.total_tracks = reaper.CountTracks(0)

  local num, den, tempo = reaper.TimeMap_GetTimeSigAtTime(0, rec_start_project_pos or 0)
  session_metadata.tempo, session_metadata.num, session_metadata.den = tempo, num, den

  local retval, block_size = reaper.GetAudioDeviceInfo("BSIZE", "")
  session_metadata.block_size = (retval and block_size ~= "") and (block_size .. "-sample buffer") or "Unknown"

  session_metadata.metronome_on = reaper.GetToggleCommandState(40364) == 1 and "on" or "off"
  session_metadata.grid_visible = reaper.GetToggleCommandState(40145) == 1 and "visible" or "hidden"

  local preroll_flags = reaper.APIExists("SNM_GetIntConfigVar") and reaper.SNM_GetIntConfigVar("preroll", 0) or 0
  local preroll_play, preroll_rec = (preroll_flags & 1) == 1, (preroll_flags & 2) == 2

  if preroll_rec and preroll_play then session_metadata.preroll = "on (play & rec)"
  elseif preroll_rec then session_metadata.preroll = "on (rec)"
  elseif preroll_play then session_metadata.preroll = "on (play)"
  else session_metadata.preroll = "off" end

  local rec_mode_val = reaper.GetSetProjectInfo(0, "RECORD_MODE", 0, false)
  if rec_mode_val == 1 then session_metadata.rec_mode = "Auto-Punch (Time Sel)"
  elseif rec_mode_val == 2 then session_metadata.rec_mode = "Record Input (Force)"
  elseif rec_mode_val == 3 then session_metadata.rec_mode = "MIDI Overdub/Replace"
  else session_metadata.rec_mode = "Normal" end

  session_metadata.armed_input_count = 0
  for i = 0, session_metadata.total_tracks - 1 do
    if reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, i), "I_RECARM") > 0 then session_metadata.armed_input_count = session_metadata.armed_input_count + 1 end
  end
  session_metadata.device_name = GetDeviceNameFromIni()
end

function CommitOrDiscardLog(wall_time, armed_lines, inventory_lines, notes_lines)
  if not ENABLE_LOGGING then return end

  local total_recorded = total_recording_time
  if total_recorded < MIN_LOG_DURATION_SEC or not session_metadata.log_path or session_metadata.proj_path == "" then return end

  local project_span = GetProjectTimeSpan()
  local file = SafeOpen(session_metadata.log_path, "w")
  if not file then return end

  local out = {}
  table.insert(out, string.format("%-55s  %s\n", session_metadata.studio_name .. " — SESSION AUDITOR LOG v7.3", session_metadata.studio_location))
  table.insert(out, string.format("%-38s %s → %s\n", session_metadata.proj_name, session_metadata.start_time, os.date("%H:%M:%S")))
  table.insert(out, string.format("Log: %s\n     in %s\n\n", session_metadata.log_filename, session_metadata.output_dir))

  local status_code, status_reason = "OK", "session completed normally"
  if session_summary_data.dead_tracks > 0 then
      status_code, status_reason = "WARNING", string.format("%d track(s) contained no usable audio", session_summary_data.dead_tracks)
  elseif session_hardware_changes > 0 or session_disk_warnings > 0 or session_underruns > 0 then
      status_code, status_reason = "WARNING", "hardware or disk warnings occurred during tracking"
  end

  table.insert(out, string.format("STATUS  %s — %s\n", status_code, status_reason))
  if session_metadata.sys_warn then table.insert(out, "  " .. session_metadata.sys_warn .. "\n") end
  if session_metadata.sr_warn then table.insert(out, "  " .. session_metadata.sr_warn .. "\n") end
  if session_metadata.crash_warn then table.insert(out, "  " .. session_metadata.crash_warn .. "\n") end

  table.insert(out, string.format("  Duration %s · Span %s (%s–%s) · %d pass%s\n", WallTimeToHMS(total_recorded), WallTimeToHMS(project_span), ProjectPosToTimecode(rec_start_project_pos or 0), ProjectPosToTimecode(rec_stop_project_pos or 0), session_record_button_presses, session_record_button_presses > 1 and "es" or ""))
  table.insert(out, string.format("  Armed %d · Recorded %d · Dead %d · Clips %d · Underruns %d · Disk warn %d · Hw chg %d\n", session_metadata.armed_input_count, session_metadata.armed_input_count - session_summary_data.dead_tracks, session_summary_data.dead_tracks, session_summary_data.total_clips, session_underruns, session_disk_warnings, session_hardware_changes))
  local journal_status
  if not ENABLE_EVENT_JOURNAL then
    journal_status = "Disabled"
  elseif journal_runtime_disabled then
    journal_status = string.format("Disabled mid-session after write failures (partial, %s)", KEEP_JOURNAL_FILE_AFTER_BUILD and ("kept: " .. session_metadata.journal_filename) or "discarded")
  elseif KEEP_JOURNAL_FILE_AFTER_BUILD then
    journal_status = string.format("Kept (%s)", session_metadata.journal_filename)
  else
    journal_status = "discarded after compile"
  end
  table.insert(out, string.format("  Journal: %s\n\n", journal_status))

  table.insert(out, "SYSTEM\n")
  table.insert(out, string.format("  %s · %d Hz / %d-bit · %s · %s\n", session_metadata.os_string, session_metadata.sr, session_metadata.bd, session_metadata.device_name, session_metadata.block_size))
  table.insert(out, string.format("  %.2f BPM %d/%d · Click %s · Grid %s · Pre-roll %s · %s\n", session_metadata.tempo, session_metadata.num, session_metadata.den, session_metadata.metronome_on, session_metadata.grid_visible, session_metadata.preroll, session_metadata.rec_mode))
  table.insert(out, string.format("  %s free on record drive · %d tracks in project\n\n", session_metadata.free_gb_str, session_metadata.total_tracks))

  table.insert(out, "ARMED\n")
  if #armed_lines > 0 then table.insert(out, table.concat(armed_lines, "\n") .. "\n\n") else table.insert(out, "  (No tracks armed)\n\n") end

  table.insert(out, "INVENTORY\n")
  if #inventory_lines > 0 then table.insert(out, table.concat(inventory_lines, "\n") .. "\n\n") else table.insert(out, "  (No items recorded)\n\n") end

  if #notes_lines > 0 then
      table.insert(out, "NOTES\n")
      table.insert(out, table.concat(notes_lines, "\n") .. "\n\n")
  end

  table.insert(out, "TIMELINE                                                   !\n= anomaly\n")
  table.insert(out, string.format("%-1s   %-6s   %-9s  %-3s  %-36s   %-15s   %-10s\n", " ", "TIME", "POS", "TRK", "EVENT", "REGION", "SOURCE"))
  
  table.sort(session_events, function(a,b) if a.pos==b.pos then return a.wall_time<b.wall_time end return a.pos<b.pos end)
  for _, ev in ipairs(session_events) do
    local is_anomaly = (ev.severity == "ANOMALY" or ev.severity == "CRITICAL")
    local elapsed_sec = math.max(0, ev.wall_time - rec_start_wall)
    table.insert(out, string.format("%-1s   +%-5s   %-9s  %-3s  %-36s   %-15s   %-10s\n", 
      is_anomaly and "!" or " ", string.format("%02d:%02d", math.floor(elapsed_sec / 60), math.floor(elapsed_sec % 60)), 
      ProjectPosToTimecode(ev.pos), ev.track and tostring(ev.track) or "--", ev.msg, (ev.region ~= "") and ev.region or "--", 
      is_anomaly and "[ANM]" or (ev.source and string.format("[%s]", ev.source) or "--")))
  end

  table.insert(out, "\nREGIONS AT STOP\n")
  local has_rgns = false
  for _, rgn in ipairs(region_cache) do
    has_rgns = true
    table.insert(out, string.format("  %-12s %s – %s\n", (rgn.name ~= "" and rgn.name or "Region "..rgn.idx), ProjectPosToTimecode(rgn.s), ProjectPosToTimecode(rgn.e)))
  end
  if not has_rgns then table.insert(out, "  (No regions)\n") end
  table.insert(out, "\nEOF\n")

  file:write(table.concat(out))
  file:close()
end

-- =============================================================================
-- START / STOP EVENTS
-- =============================================================================

function OnRecordingStop(wall_time)
  if not ENABLE_LOGGING then return end

  local true_end = reaper.GetPlayPosition()
  rec_stop_project_pos = true_end
  session_summary_data.total_clips, session_summary_data.dead_tracks = 0, 0
  local armed_lines, inventory_lines, notes_lines = {}, {}, {}

  for guid, name in pairs(armed_guid_set) do
    local track = FindTrackByGUID(guid)
    if track then
        local t_num = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
        local t_file, rms_str, peak_str = "No item created", "N/A", "N/A"
        local new_take_number, total_takes_on_item, item_flags = 0, 0, ""

        local found_new_item, found_new_take = FindNewlyRecordedTake(track, rec_start_project_pos, true_end)

        if found_new_item then
            local item_pos = reaper.GetMediaItemInfo_Value(found_new_item, "D_POSITION")
            if item_pos + reaper.GetMediaItemInfo_Value(found_new_item, "D_LENGTH") > true_end then true_end = item_pos + reaper.GetMediaItemInfo_Value(found_new_item, "D_LENGTH") end

            total_takes_on_item = reaper.CountTakes(found_new_item)

            if found_new_take then
                for take_idx = 0, total_takes_on_item - 1 do if reaper.GetTake(found_new_item, take_idx) == found_new_take then new_take_number = take_idx + 1 break end end

                local src = reaper.GetMediaItemTake_Source(found_new_take)
                if src then
                    local full_path = reaper.GetMediaSourceFileName(src, "")
                    if full_path ~= "" then t_file = full_path:match("^.+[/\\](.+)$") or full_path end
                end

                local peak_db, rms_db = AnalyzeTakeLoudness(found_new_take)
                if peak_db ~= -144 then peak_str = string.format("%.2f dBFS", peak_db) end
                if rms_db ~= -144 then rms_str = string.format("%.2f dBFS", rms_db) end

                if peak_db <= SILENCE_THRESHOLD_DB then
                    item_flags = " [FLAG: SILENT FILE]"
                    session_summary_data.dead_tracks = session_summary_data.dead_tracks + 1
                elseif rms_db >= UNUSABLE_RMS_DB then
                    item_flags = " [FLAG: UNUSABLE (HOT RMS)]"
                end
            end
        else
            session_summary_data.dead_tracks = session_summary_data.dead_tracks + 1
        end

        local c_count, m_peak = clip_count[guid] or 0, track_max_peak[guid]
        session_summary_data.total_clips = session_summary_data.total_clips + c_count
        local max_obs_str = m_peak and string.format("%.2f dBFS", m_peak) or "N/A"

        local init_snap = initial_track_states[guid]
        if init_snap then table.insert(armed_lines, string.format("  #%02d %-22s In: %-8s Monitor: %s", t_num, name, init_snap.input, init_snap.monitor)) end

        local take_str = total_takes_on_item > 0 and string.format("(take %d/%d)", new_take_number, total_takes_on_item) or ""
        local mode_str = init_snap and string.format("[%s]", init_snap.recmode) or ""
        table.insert(inventory_lines, string.format("  #%02d %s %s → %s  %s%s\n      Peak %s · RMS %s · Max input %s · Clips %d", t_num, name, mode_str, t_file, take_str, item_flags, peak_str, rms_str, max_obs_str, c_count))

        if found_new_item then
            ApplyGeneratedTrackNotes(track, BuildGeneratedTrackNotesBody(
                os.date("%Y-%m-%d"), t_file, new_take_number, total_takes_on_item, peak_str, rms_str, max_obs_str, c_count))
        end

        local track_notes = ParseTrackNotesMetadata(track)
        if track_notes then table.insert(notes_lines, string.format("  #%02d %s", t_num, track_notes)) end
    end
  end

  QueueEvent(wall_time, true_end, "Recording stopped", "EVENT", nil, nil, nil, nil, "SYS", "--")
  CommitOrDiscardLog(wall_time, armed_lines, inventory_lines, notes_lines)
  FinalizeJournal()

  if CONFIG_SHOW_POPUP then reaper.MB("REAPER Session Auditor:\nSession log compiled and saved successfully.", "Session Auditor", 0) end
end

-- =============================================================================
-- MAIN LOOP
-- =============================================================================

function MonitorEverything()
  local play_state, wall_time = reaper.GetPlayState(), reaper.time_precise()

  if play_state & 4 == 4 then
      total_recording_time = total_recording_time + (wall_time - (last_precise_time or wall_time))
  else
    if not is_cooling_down then is_cooling_down, cooldown_start_time = true, wall_time end
    if (wall_time - cooldown_start_time) >= POST_REC_WAIT_SEC then OnRecordingStop(wall_time) return end
    reaper.defer(MonitorEverything)
    return
  end

  local project_pos = reaper.GetPlayPosition()
  
  local curr_state_count = reaper.GetProjectStateChangeCount(0)
  if curr_state_count ~= last_proj_state_count then
      RebuildRegionCache()
      last_proj_state_count = curr_state_count
  end

  local rgn_idx, rgn_name = GetRegionContextAtPos(project_pos)
  if rgn_idx ~= -1 and rgn_idx ~= last_region_idx then
      QueueEvent(wall_time, project_pos, string.format("→ Region \"%s\"", rgn_name), "EVENT", "REGION_ENTER", rgn_idx, nil, nil, "SYS", "--")
      last_region_idx = rgn_idx
  end

  if play_state ~= last_play_state then
    if last_play_state ~= -1 then
      if last_play_state == 1 and play_state == 5 then
        session_record_button_presses = session_record_button_presses + 1
        QueueEvent(wall_time, project_pos, "Punched In", "EVENT", nil, nil, "[PUNCH]", COLOR_PUNCH, "SYS", "--")
      end
    end
    last_play_state = play_state
  end

  local target_tracks, is_master_fallback = {}, false
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    if reaper.GetMediaTrackInfo_Value(track, "I_RECARM") > 0 then table.insert(target_tracks, track) end
  end

  if #target_tracks == 0 then
    table.insert(target_tracks, reaper.GetMasterTrack(0))
    is_master_fallback = true
  end

  if last_precise_time ~= nil then
    local wall_gap = wall_time - last_precise_time
    if wall_gap > ENGINE_LAG_GAP_SEC and GlobalThrottle("ENGINE_LAG", "audio_engine", wall_time) then
      QueueEvent(wall_time, project_pos, string.format("Engine lag %.0fms", wall_gap * 1000.0), "ANOMALY", nil, nil, string.format("[ENGINE_LAG] %.0fms", wall_gap * 1000.0), COLOR_ENGINE_LAG, "ENG", "--")
    end
  end
  last_precise_time = wall_time

  local xrun_count = reaper.GetSetProjectInfo(0, "RENDER_NUMXRUNS", 0, false)
  if xrun_count and xrun_count > 0 then
    if last_xrun_count == nil then last_xrun_count = xrun_count
    elseif xrun_count > last_xrun_count then
      local new_xruns = xrun_count - last_xrun_count
      LogUnderrun(wall_time, project_pos, new_xruns)
      last_xrun_count, session_underruns = xrun_count, session_underruns + new_xruns
    end
  end

  for _, track in ipairs(target_tracks) do ProcessPeakChanges(wall_time, project_pos, track, is_master_fallback, CollectTrackPeakState(track)) end
  RunScheduledTasks(wall_time, project_pos, { target_tracks = target_tracks, is_master_fallback = is_master_fallback })

  reaper.defer(MonitorEverything)
end

-- =============================================================================
-- ENTRY POINT
-- =============================================================================

rec_start_wall, rec_start_project_pos = reaper.time_precise(), reaper.GetPlayPosition()
last_play_state, session_record_button_presses = reaper.GetPlayState(), 1

state.previous.hardware, state.previous.transport = CollectHardwareState(), CollectTransportState()
if not state.previous.hardware.sample_rate or state.previous.hardware.sample_rate == 0 then state.previous.hardware.sample_rate = DEFAULT_SAMPLE_RATE end

local init_tracks = {}
for i = 0, reaper.CountTracks(0) - 1 do
  local t = reaper.GetTrack(0, i)
  if reaper.GetMediaTrackInfo_Value(t, "I_RECARM") > 0 then
    table.insert(init_tracks, t)
    local _, tg = reaper.GetSetMediaTrackInfo_String(t, "GUID", "", false)
    initial_track_states[tg] = CaptureTrackStateSnapshot(t)
    state.previous.tracks[tg] = CollectTrackParamState(t)
  end
end
armed_guid_set = BuildGuidSet(init_tracks)
CachePreRecordItems(init_tracks)
RebuildRegionCache()
last_proj_state_count = reaper.GetProjectStateChangeCount(0)

if ENABLE_LOGGING then
  PreFlightChecks()
  GatherSessionMetadata()
  InitJournal()
end

RegisterTask("track_audit",    TRACK_AUDIT_INTERVAL_SEC,    RunTrackAuditTask)
RegisterTask("hardware_scan",  HARDWARE_SCAN_INTERVAL_SEC,  RunHardwareScanTask)
RegisterTask("disk_scan",      STORAGE_CHECK_INTERVAL,      RunDiskScanTask)
RegisterTask("journal_flush",  JOURNAL_FLUSH_INTERVAL_SEC,  FlushJournal)

reaper.Main_OnCommand(1013, 0)
last_play_state = reaper.GetPlayState()

reaper.defer(function()
  local pos, wall_now, arm_count = reaper.GetPlayPosition(), reaper.time_precise(), 0
  for _ in pairs(armed_guid_set) do arm_count = arm_count + 1 end
  QueueEvent(wall_now, pos, string.format("Recording started — %d armed", arm_count), "EVENT", nil, nil, string.format("[REC START] (%d Trks)", arm_count), COLOR_START, "SYS", "--")
  MonitorEverything()
end)

reaper.atexit(function() pcall(function() if ENABLE_EVENT_JOURNAL then FlushJournal() end end) end)