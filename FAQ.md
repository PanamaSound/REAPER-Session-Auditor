## FAQ

### What is REAPER Session Auditor, in one sentence?

It's a "change observer" script that runs for the duration of a recording pass: it snapshots every record-armed track, watches for anything that changes against that baseline, and logs it — clipping, hot input, dead/silent channels, fader/FX changes, arm changes, audio engine lag, buffer underruns, disk space, and hardware disconnects.

### Who is this actually useful for?

Built it for running sessions solo — no second engineer watching meters while tracking. A lot of that work is live ensemble recording: bluegrass and folk trios/quartets, multi-mic close+room hybrid setups. When you've got 7+ channels open and you're trying to be present with the musicians instead of staring at the DAW, it's easy to miss a dead channel (phantom power didn't engage, an XLR came loose) until after a take you can't always get back. This is basically a second engineer for that situation.

It's also useful for:
- Long-form sessions, where disk space and engine health matter over multiple hours
- Going back months later to reconstruct what mic was on what, or troubleshoot a session after the fact
- Punch-in/overdub-heavy sessions, where it's important to know whether a new take actually landed

### Does it detect clipping?

Yes — full real-time peak monitoring on every armed track, every frame, no debounce. This is core functionality, not an edge case.

### Does it help diagnose clicks/pops on the input?

Clipping and clicks are two different things, worth being precise about. Clicks/pops are transient glitches, usually caused by buffer underruns or xruns, not signal level. The script doesn't do waveform-level analysis to catch those directly — but it does log buffer underruns and engine lag with timestamps. So if you hear a click, you can cross-reference the timestamp against the session log and get a fast read on whether it's a digital dropout (engine/buffer issue) versus something in your analog chain (cable, connector, ground loop, etc). It narrows things down quickly, but it isn't a true root-cause click detector.

### Will it start/stop recording for me, or just watch?

It actually triggers the record action as part of starting up, then monitors for the duration of the pass and runs its wrap-up (track/take inventory, loudness pass, log compile) once recording stops.

### Will it modify my project, audio files, or track notes?

It never touches audio files. It will drop markers on the timeline as events happen (spacing between markers is configurable). If you have the generated track notes feature enabled, it appends/updates a clearly delimited `GENERATED TRACK NOTES:` block in each track's notes — it replaces only that block and leaves the rest of your notes untouched.

### What happens if REAPER crashes mid-session?

There's an optional JSON Lines (JSONL) event journal written incrementally to disk throughout the session, specifically so a hard crash doesn't erase the record of what happened up to that point. It's separate from the final human-readable log, which only gets compiled once the session ends normally.

### What does it log, and where?

A full human-readable `.txt` session log (timeline of events, per-track inventory, peak/RMS, hardware/disk health) plus the optional JSONL crash journal mentioned above. Both paths are configurable.

### Does it require the SWS extension?

Yes, for track notes integration. The rest of the script's core monitoring doesn't depend on it, but you'll want SWS installed to get the full feature set.

### What REAPER versions / platforms does it support?

Built and tested against REAPER 7.45. Tested thoroughly on macOS; should run fine on Windows but hasn't been put through its paces there yet. Not yet tested on Linux. If you hit a platform-specific issue, that's a good candidate for a PR.

### Does it work with MIDI tracks?

It's built and tested around audio tracking — peak/RMS/take detection assumes audio takes. MIDI behavior hasn't been a focus and isn't guaranteed.

### Will this slow down my session / add noticeable CPU overhead?

It's designed around a single scheduler loop with independently-timed, throttled tasks (not several competing polling loops), and tuned for typical home/project-studio track counts. It has not been built or optimized for huge sessions (100–200+ tracks) — chunk-based state reconciliation and rolling peak buffers were deliberately skipped, since that complexity isn't justified without a real use case driving it.

### Can I customize its behavior?

Yes — thresholds, intervals, marker spacing, which features are enabled (e.g. the generated track notes block), and output paths are all configurable at the top of the script.

### Dos it work on Windows?

Not at this time. Hopefully somebody steps up to make that happen.

### What won't this do? (out of scope)

- **No waveform-level DSP analysis.** No click/pop/glitch detection on the audio itself, no spectral analysis. It watches REAPER/engine state, not the signal.
- **Not built for huge sessions.** See the CPU overhead answer above.
- **Single-file by design**, not a multi-module architecture. Easiest to distribute and install as one REAPER script. If your use case needs something more modular, that's a reasonable thing to fork toward.
- **It doesn't fix anything.** No auto gain-staging, no auto-punch, no signal rerouting. It's a monitor and a logger, not a repair tool — think flight recorder, not autopilot.
- **No mixing or mastering involvement.** Strictly a tracking-phase tool.

### Is this affiliated with Cockos or the official REAPER team?

No — independent, community-built script, released under the MIT license.

### How do I contribute or report a bug?

Pull requests are welcome, especially around the items in the "out of scope" list above if any of them sound like a fun problem to take on. Open an issue on GitHub with as much detail as you can (REAPER version, OS, what you expected vs. what happened, and a log/journal excerpt if you have one).