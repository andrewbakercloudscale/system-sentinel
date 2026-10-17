# CPU Sentinel

**Find out what is using your Mac's CPU, why, and whether to do anything about it.**

CPU Sentinel lives in the menu bar. It samples every process every 5 seconds and shows the
load on a gauge, as charts and as plain-English insights. It records which apps used the
most CPU over the last day and week, and explains what each macOS process is for. When
something gets stuck at high CPU it tells you, and it can kill that process in one click or
automatically.

![The Overview tab: a load gauge, a donut of what is using CPU now, a last-hour chart by app and insights](docs/images/overview-light.png)

## Why

On a Mac that feels slow, Activity Monitor gives you a list of numbers. It doesn't tell you:

- **which processes are a problem** rather than a passing spike;
- **what a process is,** like `mediaanalysisd`, `knowledgeconstructiond` or `WindowServer`;
- **whether it's safe to kill** a process;
- **which app used the most CPU** over the last day or week.

CPU Sentinel answers each of those. It was built after a macOS energy logger
(`PerfPowerServices`) used one and a half cores for 37 hours and nothing said so.

## Highlights

| | |
|---|---|
| **Insights in plain English** | "WindowServer is busy because the screen is being captured", "Photos is analysing your library", "3 Chrome tab processes use 40% together". Click **More** to see what is happening, each process involved and who started it, and numbered steps to fix it. |
| **Explain with ChatGPT** | The sparkles button opens ChatGPT with a ready-made prompt: the process, its CPU history, your Mac model and its busiest processes, asking what it is and how to bring it down. |
| **A day and a week of history** | Hourly CPU by app for the last 24 hours or 7 days, the heaviest users and when each one peaked. Kept across restarts and sleep. |
| **Know when a process started** | Every process shows its uptime, so a renderer that has been busy for 13 days is easy to spot. |
| **Kill anything, carefully** | One-click kill for your own processes, your password for root ones, and a separate sudo button with a warning for core macOS processes. |
| **Rules that remember** | Per app: alert (the default), ignore, or auto-kill. Auto-kill is limited to 3 kills an hour per app. |
| **Dark mode, and a window you can move** | Every screen is designed for light and dark. **Pop out** moves the panel into a normal window you can drag. |

## Screenshots

### Processes
The top 30, each with uptime, a 15 minute trend, averages, memory and Kill.

![Processes tab](docs/images/processes-light.png)

### Trends
CPU by hour, stacked by app, and the heaviest users over 24 hours or 7 days.

![Trends tab](docs/images/trends-light.png)

### Events
Everything flagged, killed or auto-killed over 7 days.

![Events tab](docs/images/events-light.png)

### Settings
What counts as a stuck process, and launch at login.

![Settings tab](docs/images/settings-light.png)

### Dark mode
Every screen has its own dark design.

![Trends tab in dark mode](docs/images/trends-dark.png)

## Install

```bash
git clone https://github.com/andrewbakercloudscale/cpu-sentinel.git
cd cpu-sentinel
bash scripts/build-app.sh      # runs the tests, builds, installs to ~/Applications, launches
```

You need macOS 14 or later, and Xcode or its command line tools (`xcode-select --install`).
Look for the red chip ![menu bar icon](docs/images/menubar-normal.png) in the menu bar.

A prebuilt app is attached to each [release](https://github.com/andrewbakercloudscale/cpu-sentinel/releases).
It isn't notarised by Apple, so after moving it to Applications, run this once or macOS
won't open it:

```bash
xattr -cr "/Applications/CPU Sentinel.app"
```

## Documentation

- **[User guide](docs/guide.md):** every screen, reading the charts, insights, killing
  processes, rules, notifications, privacy and troubleshooting.
- **[Process guide](docs/processes.md):** what the common macOS background processes are,
  why they get busy, and whether to kill them.
- **[PLAN.md](PLAN.md):** design and reasoning.

## Safety, in short

- Core macOS processes (WindowServer, kernel_task, launchd, Finder, Dock and others) are never
  killed automatically and have no Kill button. Their **sudo kill** button warns you what will
  happen first.
- Root processes need your admin password and are never auto-killed.
- Auto-kill applies only to apps you opted in, at most 3 times an hour each.

## Privacy

Everything stays on your Mac. CPU Sentinel sends nothing anywhere. The only time data
leaves is when you click **Explain**. That opens ChatGPT in your browser with a prompt
describing the process and your Mac. [What's in it](docs/guide.md#explain-with-chatgpt).

## Development

```bash
swift test                     # 33 tests, including a real CPU burner that must be flagged and killed
swift build                    # debug build
bash scripts/build-app.sh      # test, build, bundle, install, launch
```

To render every tab, in light and dark, to PNG files without touching your data:

```bash
"build/CPU Sentinel.app/Contents/MacOS/CPUSentinel" --snapshot /tmp/shots --after 600 --expand 2
```

`--after` sets how many seconds to sample before rendering (default 22). `--expand` opens
only the first n insights (default all). The README screenshots are made this way.

The code is split into `SentinelCore` (sampling, detection, history, insights; tested) and
`CPUSentinel` (the SwiftUI app).
