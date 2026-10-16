# Handover: CPU Sentinel UI redesign (2026-10-16)

## State

- v0.1 is installed in `~/Applications/CPU Sentinel.app` and works (live-tested: a `yes`
  burner was flagged). Rebuild and reinstall with `bash scripts/build-app.sh`.
- This commit is **work in progress** on the redesign. The tree builds and `swift test`
  passes (23 tests), but the new UI is **not wired in yet**: the app still shows the v0.1 list.

## What the owner asked for (verbatim intent)

1. Look slick and professional, **colour everywhere**.
2. **Real icons per process**: a Claude process shows the Claude icon, Chrome shows Chrome, etc.
3. **Sorted by highest CPU**, with columns for **now, 1 min, 15 min, 60 min**, like a
   power-consumption breakdown of what has been chewing the CPU.
4. **Chrome tab**: take down just that one tab, not the whole of Chrome, and a button to
   **bring it to the foreground** first so the owner sees what they are about to kill.
5. **Protected system processes**: offer a **sudo shell command** (they show "protected" today).
6. "Think of all the nice improvements you can bring in."

Screenshot of v0.1 they were reacting to: plain list of name / pid / % / rule menu / Kill,
no icons, no colour, 440 px wide.

## Done in this commit (SentinelCore, tested)

- `ProcessSample.rssKB`: `ps` now also reads resident memory (`-o pid=,uid=,%cpu=,rss=,comm=`).
- `CPUHistory` (`Sources/SentinelCore/CPUHistory.swift`), recorded on every `Sentinel.tick`
  as `sentinel.cpuHistory`:
  - `average(pid, over: 60|900|3600, at:)`: energy-like mean (a process hot 6 of 60 min
    shows 10% of it in the 60 min column). The denominator is capped at how long the app
    has been recording, so a fresh start does not deflate the numbers.
  - `totalAverage(over:at:)`, `sparkline(pid or nil for total, over:buckets:at:)`,
    `recorded(at:)` (for "15 min (4 min so far)" labels).
  - Only samples >= 0.1% are stored; a dead pid's history is dropped.
- `AppIdentity`: `bundlePath` (OUTERMOST .app, so Chrome renderers group under Chrome),
  `appName`, `groupKey` (for a grouped-by-app view), `isSystem`.
- `Killer.killProtectedAsAdmin` (admin prompt; still refuses pid 0/1 and self) and
  `Killer.sudoCommand(for:)` -> `sudo kill -TERM <pid>   # <name>`.

## Done but not wired (app target)

- `Sources/CPUSentinel/Icons.swift`: `IconCache.shared.icon(for:)` -> app bundle icon,
  else a known CLI mapped to its app (`claude` -> Claude.app, `codex` -> Codex.app, the
  Virtualization VM -> Rancher Desktop.app), else a tinted SF Symbol tile. `IconView`.
- `Sources/CPUSentinel/ChromeTabs.swift`: AppleScript `list()`, `show(tab)` (raise
  window + select tab), `close(tab)` (just that tab), `openTaskManager()` (Window > Task
  Manager via System Events, needs Accessibility). Friendly errors for missing
  Automation (-1743) / Accessibility permissions.

## Next steps

1. **Info.plist**: add `NSAppleEventsUsageDescription` ("CPU Sentinel lists and closes
   Chrome tabs you choose."), or the Chrome calls fail silently.
2. **Model** (`Model.swift`): on each tick build rows for every process with history or
   cpu > 0: sample, now, 1m, 15m, 60m, sparkline (15 min, ~20 buckets), memory. Sort key
   enum (now / 1m / 15m / 60m / memory), default now. Optional group-by-app mode summing
   rows per `AppIdentity.groupKey`, expandable to its processes. Search filter.
3. **Views** (rewrite `CPUSentinelApp.swift`, about 720 px wide):
   - Header card: gradient (indigo to purple), big machine-load %, cores, total sparkline,
     1/15/60 min totals.
   - Column header row, clickable to sort, active column highlighted.
   - Row: `IconView`, name + subtitle (pid, root badge, policy badge, hot-for), sparkline,
     four CPU columns each with a number and a heat-coloured mini bar (green < 10, yellow
     < 40, orange < 80, red), memory, actions.
   - Actions: **Show** (activate the app: `NSRunningApplication` by pid, or by bundle URL
     for helpers), **Kill**, a "..." menu (Quit gracefully via `terminate()`, Reveal in
     Finder, Copy pid, Copy sudo command, Open Activity Monitor, rule submenu).
   - Chrome renderer and Chrome main rows: a **Tabs** popover from `ChromeTabs.list()`
     with per tab Show (eye) and Close (red x), plus "Open Chrome Task Manager".
   - Protected rows: a red-outlined **sudo** button -> `NSAlert` naming the consequence
     (WindowServer logs you out) with "Copy sudo command", "Kill with password"
     (`Killer.killProtectedAsAdmin`), "Cancel". `NSApp.activate` before `runModal`.
   - Hover highlight on rows, zebra striping, colour-coded tab bar (SF Symbols), footer
     with process count, Activity Monitor shortcut, Quit.
4. Build with `bash scripts/build-app.sh`, screenshot the menu, check against the list above.
5. Update README (columns, Chrome tabs, sudo, permissions) and commit, push.

## Gotchas

- Do not use `proc_pid_rusage`: EPERM for root processes. `ps` is the sampler on purpose.
- `ps` prints comma decimals in this locale ("94,0"); the parser handles it.
- `Darwin.kill` must be qualified inside `Killer` (name clash with `Killer.kill`).
- Kills run off the main thread; history writes go back to the main actor (data race otherwise).
- No em or en dashes in any text (owner rule).
