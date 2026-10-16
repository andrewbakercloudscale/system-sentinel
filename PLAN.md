# CPU Sentinel: plan

A macOS menu bar app that watches every process, alerts on the ones burning CPU, and kills
them on request or automatically, per process.

## Why

On 2026-10-16 the Mac sat at load 55 to 70 for hours. The causes were found by hand with `ps`:

- `PerfPowerServices` (root, a macOS daemon) stuck at 94 to 171% for 37 hours;
- one Chrome tab renderer at 38% for 3 days;
- builds failing timing tests because the machine was busy.

Nothing told the owner. The fix each time was one `kill`. This app makes that a notification
and a click, or no click at all.

## What it does (v1)

1. **Menu bar icon** that changes colour with load: normal, busy, alert. The menu lists
   the top processes with CPU %, how long each has been hot, and a Kill button.
2. **Bad actor detection.** A process is a bad actor when it stays above a CPU threshold
   for a sustained window. The defaults are 80% for 2 minutes, and both are configurable.
   Short bursts (a build, a compile) do not trigger it; a stuck daemon does.
3. **Alert.** A macOS notification with **Kill**, **Ignore for 1 h** and **Always ignore**
   buttons. Each process alerts once per episode, not every sample.
4. **Per-process policy**, set from the menu or the notification. It is keyed by executable
   path (and bundle id where there is one), so it survives restarts and new pids:
   - **Alert** (default): notify, the owner decides.
   - **Auto-kill**: SIGTERM, then SIGKILL after 5 s if it is still alive; a notification
     says what was killed and why.
   - **Ignore**: never alert (e.g. the Rancher VM during a build).
5. **History.** A log of what was flagged and killed, viewable from the menu.

## Safety rules (hard-coded, not settings)

- **Never killed, never offered:** `kernel_task`, `launchd`, `WindowServer`, `loginwindow`,
  `Finder`, `Dock`, `SystemUIServer`, `coreaudiod`, and the app itself. Killing these logs
  you out or hangs the Mac.
- **Restartable root daemons** (e.g. `PerfPowerServices`) can be killed manually, never
  automatically by default. launchd restarts them.
- Auto-kill applies only to processes the owner opted in, by name, at least once.
- Auto-kill rate limit: the same executable at most 3 times an hour. After that it alerts
  instead, because a process that keeps coming back needs a person, not a loop.

## Chrome tabs

Chrome runs each site in a renderer process, so killing one closes that site's tabs with
"Aw, Snap". The app shows renderers as "Chrome tab (renderer 18060)". It cannot name the tab:
Chrome does not expose the tab-to-pid map outside its own Task Manager. Option for v2: a small
Chrome extension. Its `chrome.processes` API is dev-channel only, so that is a research item,
not a promise.

## Root processes

`PerfPowerServices` runs as root, so a normal app cannot signal it.

- **v1:** manual kill asks for the admin password via the standard macOS prompt.
- **v2:** a privileged helper registered with `SMAppService`, approved once in System
  Settings, so root kills need no password. This needs Developer ID signing.

## Technical approach

- **Swift 6, SwiftUI `MenuBarExtra`**, macOS 14+. No Dock icon (`LSUIElement`).
- **Sampling every 5 s** via `libproc`: `proc_listallpids` plus `proc_pid_rusage`
  (`ri_user_time + ri_system_time`). CPU % is the delta between samples, so there is no
  `ps` subprocess and the cost is under 1% CPU.
- **Notifications:** `UserNotifications` with action buttons.
- **Kill:** `kill(2)` for user processes; an `osascript` admin prompt for root ones in v1.
- **Settings and policies:** a JSON file in `~/Library/Application Support/CPUSentinel/`.
- **Launch at login:** `SMAppService.mainApp`.
- **Build:** a Swift Package plus a script that assembles the `.app`. Ad-hoc signed for local
  use; Developer ID and notarisation only if it is ever shared.

## Milestones

| # | Deliverable | Done when |
|---|---|---|
| 1 | Sampler + menu listing top processes with CPU % | the numbers match Activity Monitor within 5 points |
| 2 | Bad actor detection + notifications | a `yes > /dev/null` loop alerts after the window, a 30 s burst does not |
| 3 | Manual kill (user + root via prompt) | kills the test loop; the deny list refuses WindowServer |
| 4 | Per-process policy + auto-kill + rate limit | auto-kill fires, then stops at 3 an hour |
| 5 | History, launch at login, settings UI | survives a reboot with policies intact |
| 6 (v2) | Privileged helper, Chrome tab names | needs signing; research item |

## Tests

- Unit: CPU % maths from rusage deltas, the sustained-window detector (bursts vs steady),
  policy matching by path, the deny list, the rate limiter.
- Integration: spawn a CPU burner, assert alert then kill; assert the deny list holds.
- Every test runs in `swift test`, no UI needed.

## Open decisions

- Default threshold and window (proposed: 80% for 2 min).
- Whether `Ignore` should expire (proposed: per-entry choice of 1 h or forever).
