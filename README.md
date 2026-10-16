# CPU Sentinel

A macOS menu bar app that shows what is using your CPU, explains why, and kills what you
choose, by hand or automatically per process. Design and reasoning: [PLAN.md](PLAN.md).

## Install

```bash
bash scripts/build-app.sh      # runs the tests, builds, installs to ~/Applications, launches
```

Needs Xcode (or its command line tools) and macOS 14+. On first launch macOS asks to allow
notifications: allow them, or alerts only show in the menu. The app is ad-hoc signed, so it
runs on the Mac that built it; sharing a build needs a Developer ID and notarisation.

## Use

The red chip in the menu bar opens the panel. **Pop out** moves it into a normal window you
can drag and resize.

- **Overview:** a gauge of the whole Mac, cores busy, thermal state, 1, 15 and 60 minute
  averages, a donut of what is using CPU now and a stacked chart of the last hour.
  Below that, **insights**: plain-language findings such as sustained high CPU, overheating,
  an unfamiliar macOS service, many copies of one app adding up, a repeat offender, or
  WindowServer busy because something is capturing the screen. **More** on any insight
  shows what is happening, each process involved (what it is, which app started it, its CPU,
  with Explain and Kill buttons) and numbered steps to fix it.
- **Processes:** the top 30, filterable and sortable by now, 15 minutes, 1 hour or memory.
  Each row shows when the process started, a 15 minute sparkline, its averages and memory,
  an info popover with a guide to known macOS processes, and Kill or Sudo.
- **Trends:** the last 24 hours or 7 days, stacked by app or by process, and the heaviest
  users with their share, average, peak and when they peaked. Kept across restarts.
- **Events:** what was flagged, killed, auto-killed or failed to die, charted over 7 days.
- **Rules:** every per-process rule, removable. **Settings:** threshold, window and launch at
  login, applied with Save.
- **Explain** (sparkles button) opens ChatGPT with a prompt describing the process or
  insight, your Mac and its busiest processes, asking what it is and how to bring it down.
- **Notification** when a process stays over the threshold (default 80% for 2 minutes):
  Kill, Ignore for 1 hour, Always ignore, or Always auto-kill.

100% means one core in the process lists; the charts show percent of the whole Mac.

## Safety

- Core macOS processes (WindowServer, kernel_task, launchd, loginwindow, Finder, Dock and
  others) are never auto-killed and have no Kill button. **Sudo** kills one after a warning
  of what will happen (killing WindowServer logs you out) and an admin password, or opens a
  Terminal with the `sudo kill` command typed in. pid 0, pid 1 and the app itself are
  always refused.
- Root processes (e.g. PerfPowerServices) are killed by hand only, with your password.
- Auto-kill only for processes you opted in, and at most 3 times an hour per app.
- Killing a "Chrome tab (renderer N)" closes that site's tabs with "Aw, Snap"; Chrome does
  not reveal which tab a renderer serves.

## Files

All in `~/Library/Application Support/CPUSentinel/`:

- Rules: `policies.json`
- Events: `history.jsonl`
- Hourly usage for Trends (7 days): `usage-24h.json`

## Tests

`swift test`: 31 tests, including a real `yes` burner that must be seen, flagged and killed,
checks that protected and root processes are never auto-killed, hourly usage accounting
across sleep gaps, and the insight rules.
