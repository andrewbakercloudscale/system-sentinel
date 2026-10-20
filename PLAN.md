# System Sentinel: plan

A macOS menu bar app that finds what is wrong with a Mac and fixes it in a click. It began
as a watcher for processes burning CPU (it was called CPU Sentinel until v0.7.0) and now
covers memory, energy, storage, network and a checkup of common problems.

## Why

On 2026-10-16 the Mac sat at load 55 to 70 for hours. The causes were found by hand with `ps`:

- `PerfPowerServices` (root, a macOS daemon) stuck at 94 to 171% for 37 hours;
- one Chrome tab renderer at 38% for 3 days;
- builds failing timing tests because the machine was busy.

Nothing told the owner. The fix each time was one `kill`. This app makes that a notification
and a click, or no click at all.

## What v1 set out to do (all shipped)

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
- **Sampling every 5 s** via `ps`
  at about 30 ms a run. `proc_pid_rusage` was the plan and returns EPERM for every root
  process; `ps` holds a private entitlement an ad-hoc app cannot. Cost: under 1% CPU.
- **Notifications:** `UserNotifications` with action buttons.
- **Kill:** `kill(2)` for user processes; an `osascript` admin prompt for root ones in v1.
- **Settings and policies:** a JSON file in `~/Library/Application Support/SystemSentinel/`.
- **Launch at login:** `SMAppService.mainApp`.
- **Build:** a Swift Package plus `scripts/build-app.sh`, which assembles the `.app`.
  Releases (`scripts/release.sh`) are signed with a stable local identity, so macOS keeps
  its permissions across updates and the in-app updater can check the download came from
  the same signer. Developer ID and notarisation are supported but not yet used.

## Where it stands (v0.8.18)

Milestones 1 to 5 shipped in v0.1 to v0.6. Since then:

- **Checkup**, the first tab: what is wrong, found on its own or picked from eleven symptoms,
  each with fixes; then security, network, startup items, crashes and backups, performance
  first and security last; and the everyday restarts. Findings can be ignored.
- Nine tabs: **Checkup**, **Overview** (load, now, last hour, cores, memory; a **Trends** page
  for CPU over time), **Processes**, **Memory**, **Storage** (what grew, cleanups, large
  files), **Network** (connections by app, DNS map, route test over time), **Energy** (power,
  battery health, sleep and wakes), **Events**, **Settings** (a **Rules** page, which also
  lists everything that starts by itself, each with a remove button).
- Plain-English insights with one-click fixes, alarms for heat and power, weekly reports,
  and an in-app updater.

## Next

1. **Time Machine:** whether a backup is stuck, not only whether one is set up.
2. **Developer ID and notarisation**, then a privileged helper (`SMAppService`) so root
   kills need no password.
3. **Chrome tab names** for renderer processes: research, as `chrome.processes` is dev-channel only.

## Tests

- Unit: CPU % maths from rusage deltas, the sustained-window detector (bursts vs steady),
  policy matching by path, the deny list, the rate limiter.
- Integration: spawn a CPU burner, assert alert then kill; assert the deny list holds.
- Every test runs in `swift test`, no UI needed.
