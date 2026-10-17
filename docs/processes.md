# Process guide

[Back to README](../README.md) · [User guide](guide.md)

What the processes you're likely to see near the top of the list are, why they get busy,
and what to do. System Sentinel shows the same notes in the ⓘ popover, in insights and in the
Explain prompt. For anything not listed, use ✨ **Explain**.

**Verdicts**

| Verdict | Meaning |
|---|---|
| ⏳ **Wait** | Normal background work that finishes on its own. Killing it only postpones the work. |
| ✅ **Safe to stop** | Fine to quit or kill; macOS starts it again when needed. |
| ✋ **Do not kill** | macOS depends on it. Find what is making it busy instead. |
| 👤 **Yours** | Something you started. Your call. |

---

## Indexing, Photos and on-device intelligence

These are the usual cause of a busy Mac after a macOS update, a migration or a large import.
They run hardest when the Mac is idle and on power, and settle within hours or a day or two.

| Process | What it is | Verdict |
|---|---|---|
| `mds`, `mds_stores`, `mdworker` | **Spotlight indexing.** Reads new and changed files so search can find them. Spikes after an update, a big download or a new disk. | ⏳ Wait |
| `corespotlightd` | **Spotlight indexing app content** from Mail, Notes and Messages. Busy after big syncs. | ⏳ Wait |
| `mediaanalysisd` | **Photos analysing your library:** faces, scenes and text in photos and videos. Stops when the library is done. | ⏳ Wait |
| `photoanalysisd` | **Photos building People and Memories,** after imports or a Photos upgrade. | ⏳ Wait |
| `photolibraryd` | **Photos library service.** Busy during imports and iCloud Photos syncs. | ⏳ Wait |
| `knowledgeconstructiond` | **On-device knowledge** for Siri, Spotlight suggestions and Apple Intelligence, built from mail, messages and calendar. Heavy after updates. | ⏳ Wait |
| `suggestd` | **Siri Suggestions:** scans mail and messages for contacts and events. | ⏳ Wait |

## Sync, backup and updates

| Process | What it is | Verdict |
|---|---|---|
| `cloudd` | **iCloud syncing.** Busy after adding many files or signing in on a new Mac. | ⏳ Wait |
| `bird` | **iCloud Drive syncing.** A large folder change keeps it busy for a while. | ⏳ Wait |
| `fileproviderd` | **Cloud files** for iCloud Drive, Dropbox, OneDrive and Google Drive in Finder. | ⏳ Wait |
| `nsurlsessiond` | **Background downloads** for apps: updates, podcasts, iCloud. | ⏳ Wait |
| `backupd` | **Time Machine.** Busy during a backup, especially the first. | ⏳ Wait |
| `softwareupdated` | **Preparing a macOS update.** Settles once the update is staged. | ⏳ Wait |

## Security

| Process | What it is | Verdict |
|---|---|---|
| `trustd` | **Checking certificates** for apps and websites. Brief spikes are normal. | ⏳ Wait |
| `syspolicyd` | **Gatekeeper** checking a new or updated app the first time it opens. | ⏳ Wait |
| `XprotectService` | **Apple's malware scan.** Short bursts after downloads and updates. | ⏳ Wait |
| `tccd` | **Privacy permissions:** answers apps asking for camera, screen, files and automation access. Busy means some app is asking very often. | ⏳ Wait |
| `ZscalerService` | **Zscaler,** a company network security agent. Rises with heavy browsing or downloads. Managed by IT. | ✋ Do not kill |

## Core macOS

| Process | What it is | Verdict |
|---|---|---|
| `WindowServer` | **Draws everything on your screens.** Rises with screen capture (screenshot tools, screen sharing, AI agents that take screenshots), scaled resolutions on external displays, high refresh rates, transparency and animated content. **Killing it logs you out at once.** See [WindowServer and screen capture](guide.md#example-windowserver-and-screen-capture). | ✋ Do not kill |
| `kernel_task` | **Your Mac cooling itself.** macOS reserves CPU time here to slow everything else down when it's too hot. It's a symptom, not a cause: find what else is busy, check airflow, unplug a warm charger. | ✋ Do not kill |
| `coreaudiod` | **Sound.** Mixes all audio. High CPU usually means an audio app or plug-in is busy. | ✋ Do not kill |
| `logd` | **System logging.** Busy when some process logs heavily; find that process instead. | ✋ Do not kill |
| `cfprefsd` | **Preferences.** Busy means an app is writing its settings in a loop. | ✋ Do not kill |
| `PerfPowerServices` | **Energy logging** for battery and energy use. Sometimes gets stuck at high CPU for hours; killing it as admin is safe, launchd restarts it. | ✅ Safe to stop |
| `ReportCrash` | **Writing a crash report.** If it keeps coming back, an app is crashing repeatedly: check Console > Crash Reports. | ⏳ Wait |

## Screen capture

Each capture makes WindowServer draw a full frame, so these also raise WindowServer.

| Process | What it is | Verdict |
|---|---|---|
| `SkyComputerUseService` | **An AI computer-use agent** (Sky, now part of ChatGPT). Screenshots your screen so the AI can see it, often several a second while it works. | 👤 Yours |
| `Codex Computer Use` | **OpenAI Codex's computer-use helper.** Screenshots the screen so Codex can see and click. | 👤 Yours |
| `replayd` | **macOS screen recording.** Busy while any app records, streams or shares the screen. Stop the recording, not replayd. | 👤 Yours |
| `screencapture` | **The screenshot command.** If it keeps reappearing, an app is taking screenshots in a loop; "started by" in the insight shows which. | ✅ Safe to stop |
| `screencaptureui` | **The screenshot toolbar and recording overlay** (Cmd-Shift-5). | ✅ Safe to stop |
| `ScreenSharingAgent`, `screensharingd` | **Screen Sharing:** someone is viewing or controlling this Mac. | 👤 Yours |

## Apps and developer tools

| Process | What it is | Verdict |
|---|---|---|
| `Google Chrome Helper`, "Chrome tab (renderer N)" | **Chrome tabs and extensions,** each site in its own process. Chrome's Task Manager (Window menu) shows which tab is which. | 👤 Yours |
| `com.apple.Virtualization.VirtualMachine` | **A virtual machine:** Docker, Rancher Desktop, UTM or Parallels. Look inside the containers or guest OS, not at the Mac. | 👤 Yours |
| `claude` | **A Claude Code session,** one per terminal. Several idle sessions add up. | 👤 Yours |
| `node` | **A Node.js program:** dev servers, build tools, language servers and many command-line tools. | 👤 Yours |
| `swift-frontend`, `clang` | **Compiling** Swift, C or Objective-C. Stops when the build ends. | 👤 Yours |

---

Missing a process that often shows up on your Mac? The notes live in
`Sources/SentinelCore/Insights.swift` (`ProcessGuide.notes`). Add one in the same shape.
