# REAPER Session Auditor

A recording safety net for REAPER. This script monitors your session in real-time, watching for potential technical failures before they ruin a take.

## What it does
* **Monitors:** Clips, hot input, silent tracks, engine lags, buffer underruns, and hardware changes.
* **Safety:** Tracks disk space and storage disconnections.
* **Documentation:** Generates a detailed, human-readable session log for every recording pass.
* **Recovery:** Maintains a JSON event journal to assist in crash recovery.
* **Annotation:** Automatically generates and updates SWS track notes with take metadata.

## About the Project
This tool was created to solve specific recording safety needs at **Panama Sound**. It is built using an observer-pattern pipeline to ensure low overhead while providing high-reliability monitoring.

## Maintenance Note
I am a studio engineer, not a professional software developer. I built this script iteratively using AI assistance. It works reliably in our production environment, but I am not personally maintaining it as a commercial product. 

## Frequently Asked Questions
Please see the FAQ at: https://github.com/PanamaSound/REAPER-Session-Auditor/blob/main/FAQ.md

**Community contributions are highly encouraged!** If you find a bug, have an idea for a feature, or want to refactor the code, please submit a Pull Request.

## Installation
1. Download `REAPER_Session_Auditor.lua`.
2. Move it to your REAPER Scripts folder: `Options > Show REAPER resource path in explorer/finder > Scripts`.
3. Run it via the Action List (`Actions > Show action list > New Action > Load ReaScript`).

## License
This project is open-source and free to use. See the license file for details.
