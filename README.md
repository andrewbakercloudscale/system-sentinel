# CPU Sentinel

A macOS menu bar app that alerts on processes burning CPU and kills them, manually or
automatically per process. Design and reasoning: [PLAN.md](PLAN.md).

## Install

```bash
bash scripts/build-app.sh      # runs the tests, builds, installs to ~/Applications, launches
```

Needs Xcode (or its command line tools) and macOS 14+. On first launch macOS asks to allow
notifications: allow them, or alerts only show in the menu.

## Use

- **Menu bar icon:** gauge when normal, orange gauge when the Mac is busy (60%+ of all
  cores), red warning when a process has been flagged.
- **Processes tab:** the top 10 by CPU, how long each has been hot, a Kill button and a
  rule menu per process.
- **Notification** when a process stays over the threshold (default 80% for 2 minutes):
  Kill, Ignore for 1 hour, Always ignore, or Always auto-kill.
- **Rules tab:** every per-process rule, removable. **History tab:** what was flagged and
  killed. **Settings:** threshold, window, launch at login.

## Safety

- Never killable: WindowServer, kernel_task, launchd, loginwindow, Finder, Dock and other
  core macOS processes, and the app itself.
- Root processes (e.g. PerfPowerServices) are killed by hand only, with your password.
- Auto-kill only for processes you opted in, and at most 3 times an hour per app.
- Killing a "Chrome tab (renderer N)" closes that site's tabs with "Aw, Snap"; Chrome does
  not reveal which tab a renderer serves.

## Files

- Rules: `~/Library/Application Support/CPUSentinel/policies.json`
- History: `~/Library/Application Support/CPUSentinel/history.jsonl`

## Tests

`swift test`: 17 tests, including a real `yes` burner that must be seen, flagged and killed,
and checks that protected and root processes are never auto-killed.
