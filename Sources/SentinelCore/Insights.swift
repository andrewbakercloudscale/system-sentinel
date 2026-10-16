import Foundation

/// Plain-English notes on the processes people most often find chewing their CPU and do
/// not recognise. The question is never "what is this binary" but "should I worry, and
/// what do I do", so every entry answers that.
public enum ProcessGuide {
    public enum Verdict: String, Sendable {
        /// Normal background work that finishes on its own.
        case wait
        /// Fine to quit or kill; it comes back when needed.
        case safe
        /// Do not kill: the Mac depends on it.
        case avoid
        /// Something you started; your call.
        case yours
    }

    public struct Note: Equatable, Sendable {
        public let headline: String
        public let detail: String
        public let verdict: Verdict
    }

    public static func note(for name: String) -> Note? {
        if name.hasPrefix("mdworker") { return notes["mdworker"] }
        if name.hasPrefix("Google Chrome Helper") { return notes["Google Chrome Helper"] }
        return notes[name]
    }

    static let notes: [String: Note] = {
        let spotlight = Note(
            headline: "Spotlight is indexing",
            detail: "Spotlight reads new and changed files so search can find them. It spikes after a macOS update, a big download or a new disk, and settles once it catches up.",
            verdict: .wait)
        return [
            "mds": spotlight, "mds_stores": spotlight, "mdworker": spotlight, "corespotlightd": Note(
                headline: "Spotlight is indexing app content",
                detail: "Indexes what apps (Mail, Notes, Messages) hand to Spotlight. Busy after big syncs; settles by itself.",
                verdict: .wait),
            "mediaanalysisd": Note(
                headline: "Photos is analysing your library",
                detail: "Finds faces, scenes and text in photos and videos. It runs while the Mac is idle and plugged in, and stops when the library is done. Killing it only postpones the work.",
                verdict: .wait),
            "photoanalysisd": Note(
                headline: "Photos is building People and Memories",
                detail: "Runs after imports or a Photos upgrade and finishes on its own. Leaving Photos closed and the Mac on power lets it finish sooner.",
                verdict: .wait),
            "knowledgeconstructiond": Note(
                headline: "macOS is building its on-device knowledge",
                detail: "Feeds Siri, Spotlight suggestions and Apple Intelligence from your mail, messages and calendar. Heavy after updates; it calms down within hours.",
                verdict: .wait),
            "kernel_task": Note(
                headline: "Your Mac is cooling itself",
                detail: "macOS reserves CPU time under kernel_task to slow everything else down when it is too hot. It is a symptom, not a culprit: find what else is busy, check airflow, unplug a warm charger.",
                verdict: .avoid),
            "WindowServer": Note(
                headline: "Drawing everything on your screens",
                detail: "It composites every window on every display. It rises with screen capture (screenshot tools, screen sharing, AI computer-use agents that take screenshots), scaled resolutions on external displays, high refresh rates, transparency and animated content. Killing it logs you out at once.",
                verdict: .avoid),
            "backupd": Note(
                headline: "Time Machine is backing up",
                detail: "Busy while a backup runs, especially the first one. Finishes on its own.",
                verdict: .wait),
            "softwareupdated": Note(
                headline: "macOS is preparing an update",
                detail: "Downloading or unpacking an update. It settles once the update is staged.",
                verdict: .wait),
            "cloudd": Note(
                headline: "iCloud is syncing",
                detail: "Uploads and downloads iCloud data. Busy after adding many files or signing in on a new Mac.",
                verdict: .wait),
            "bird": Note(
                headline: "iCloud Drive is syncing",
                detail: "Keeps iCloud Drive files in step. A large folder change keeps it busy for a while.",
                verdict: .wait),
            "fileproviderd": Note(
                headline: "Cloud files are syncing",
                detail: "Serves iCloud Drive, Dropbox, OneDrive and Google Drive files to Finder. Busy during big syncs.",
                verdict: .wait),
            "trustd": Note(
                headline: "Checking certificates",
                detail: "Verifies security certificates for apps and websites. Brief spikes are normal.",
                verdict: .wait),
            "syspolicyd": Note(
                headline: "Gatekeeper is checking an app",
                detail: "Scans apps the first time they open, so a new or updated app can keep it busy briefly.",
                verdict: .wait),
            "XprotectService": Note(
                headline: "Scanning for malware",
                detail: "Apple's built-in malware scan. Short bursts after downloads and updates are normal.",
                verdict: .wait),
            "PerfPowerServices": Note(
                headline: "Energy logging",
                detail: "Records battery and energy use. It occasionally gets stuck at high CPU for hours; killing it as admin is safe, launchd restarts it.",
                verdict: .safe),
            "nsurlsessiond": Note(
                headline: "Background downloads",
                detail: "Downloads for apps while they are in the background (updates, podcasts, iCloud).",
                verdict: .wait),
            "photolibraryd": Note(
                headline: "Photos library service",
                detail: "Reads and writes the Photos library. Busy during imports and iCloud Photos syncs.",
                verdict: .wait),
            "ReportCrash": Note(
                headline: "Something crashed",
                detail: "Writing a crash report. If it keeps coming back, an app is crashing repeatedly; check Console > Crash Reports.",
                verdict: .wait),
            "com.apple.Virtualization.VirtualMachine": Note(
                headline: "A virtual machine",
                detail: "CPU used inside a VM (Docker, Rancher Desktop, UTM, Parallels). Look at the containers or guest OS, not the Mac.",
                verdict: .yours),
            "screencaptureui": Note(
                headline: "Screenshot or recording tools",
                detail: "The screenshot toolbar and recording overlay. Busy while recording the screen.",
                verdict: .safe),
            "screencapture": Note(
                headline: "Taking a screenshot or recording",
                detail: "Busy while a screen recording runs. Stopping the recording stops it.",
                verdict: .safe),
            "Google Chrome Helper": Note(
                headline: "Chrome tabs and extensions",
                detail: "Chrome runs each site and extension in its own helper. Chrome's Task Manager (Window menu) shows which tab is which.",
                verdict: .yours),
            "claude": Note(
                headline: "A Claude Code session",
                detail: "Each terminal running Claude Code is one process. Several idle sessions add up.",
                verdict: .yours),
            "node": Note(
                headline: "A Node.js program",
                detail: "Dev servers, build tools, language servers and many CLIs run on Node.",
                verdict: .yours),
            "swift-frontend": Note(headline: "Compiling Swift", detail: "Xcode or swift build is compiling. Stops when the build ends.", verdict: .yours),
            "clang": Note(headline: "Compiling C or Objective-C", detail: "A build is running. Stops when it ends.", verdict: .yours),
            "coreaudiod": Note(headline: "Sound", detail: "Mixes all audio. High CPU usually means an audio app or plug-in is busy.", verdict: .avoid),
            "suggestd": Note(headline: "Siri Suggestions", detail: "Scans mail and messages for contacts and events to suggest. Settles on its own.", verdict: .wait),
            "tccd": Note(headline: "Privacy permissions", detail: "Answers apps asking for camera, screen, files and automation access. A busy tccd means some app is asking very often.", verdict: .wait),
            "logd": Note(headline: "System logging", detail: "Busy when some process logs heavily. Find the noisy process rather than logd.", verdict: .avoid),
            "cfprefsd": Note(headline: "Preferences", detail: "Reads and writes app settings. A busy cfprefsd means an app is writing settings in a loop.", verdict: .avoid),
            "ZscalerService": Note(headline: "Zscaler network security", detail: "Your company's security agent inspects network traffic. Heavy browsing or downloads raise it. Managed by IT.", verdict: .avoid),
        ]
    }()
}

/// One observation for the Overview: what is going on and what to do about it.
public struct Insight: Equatable, Sendable, Identifiable {
    public enum Tone: Int, Sendable, Comparable {
        case good, info, warning, critical
        public static func < (a: Tone, b: Tone) -> Bool { a.rawValue < b.rawValue }
    }

    public let id: String
    public let tone: Tone
    /// An SF Symbol name.
    public let symbol: String
    public let title: String
    public let detail: String
    /// The longer explanation shown when the insight is expanded.
    public var why: String?
    /// What to do, in order.
    public var steps: [String] = []
    /// The processes involved, each with what it is and who started it.
    public var related: [Related] = []

    public struct Related: Equatable, Sendable, Identifiable {
        public let sample: ProcessSample
        public let about: String?
        public let parent: String?
        public var id: Int32 { sample.pid }
    }

    public var expandable: Bool { why != nil || !steps.isEmpty || !related.isEmpty }

    public init(id: String, tone: Tone, symbol: String, title: String, detail: String) {
        self.id = id
        self.tone = tone
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }
}

/// Everything the insights look at, gathered by the app on each refresh.
public struct InsightInput: Sendable {
    public var cores: Double
    /// The latest sample.
    public var samples: [ProcessSample]
    /// Machine total, in percent of one core, averaged over 1, 15 and 60 minutes.
    public var total1m: Double
    public var total15m: Double
    public var total60m: Double
    /// 15 minute average per pid.
    public var avg15m: [Int32: Double]
    /// Minutes of history behind the 15 minute averages.
    public var recordedMinutes: Double
    /// By app, last 24 hours, heaviest first.
    public var daily: [DailyUsage.Summary]
    public var dailySampled: TimeInterval
    /// Machine total per hour over the last 24 hours, oldest first, with each hour's start.
    public var totalHourly: [Double]
    public var hourStarts: [Date]
    public var events: [HistoryEntry]
    /// ProcessInfo.ThermalState raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermal: Int
    public var lowPower: Bool
    /// pid to the name of the process that started it, for the busy ones.
    public var parents: [Int32: String] = [:]

    public init(cores: Double, samples: [ProcessSample], total1m: Double, total15m: Double, total60m: Double,
                avg15m: [Int32: Double], recordedMinutes: Double, daily: [DailyUsage.Summary], dailySampled: TimeInterval,
                totalHourly: [Double], hourStarts: [Date], events: [HistoryEntry], thermal: Int, lowPower: Bool, parents: [Int32: String] = [:]) {
        self.parents = parents
        self.cores = cores
        self.samples = samples
        self.total1m = total1m
        self.total15m = total15m
        self.total60m = total60m
        self.avg15m = avg15m
        self.recordedMinutes = recordedMinutes
        self.daily = daily
        self.dailySampled = dailySampled
        self.totalHourly = totalHourly
        self.hourStarts = hourStarts
        self.events = events
        self.thermal = thermal
        self.lowPower = lowPower
    }
}

/// Turns numbers into sentences. Each rule earns its place by answering a question people
/// actually ask: is my Mac busy, why, is that normal, who is the worst, should I act.
public enum Insights {
    public static func generate(_ i: InsightInput, at now: Date = Date()) -> [Insight] {
        var out: [Insight] = []
        let cores = max(i.cores, 1)
        let load = i.total1m / cores

        // Heat first: it changes how every other number should be read.
        switch i.thermal {
        case 3: out.append(Insight(id: "thermal", tone: .critical, symbol: "thermometer.sun.fill",
                                   title: "Your Mac is overheating and heavily throttled",
                                   detail: "macOS is slowing everything down to cool off. Close the busiest apps below and give it airflow."))
        case 2: out.append(Insight(id: "thermal", tone: .warning, symbol: "thermometer.high",
                                   title: "Your Mac is hot and throttling",
                                   detail: "Performance is reduced until it cools. The heaviest processes below are the ones to stop."))
        case 1: out.append(Insight(id: "thermal", tone: .info, symbol: "thermometer.medium",
                                   title: "Running warm",
                                   detail: "Not throttling yet. Fans may be audible."))
        default: break
        }
        if i.lowPower {
            out.append(Insight(id: "lowpower", tone: .info, symbol: "leaf.fill", title: "Low Power Mode is on",
                               detail: "The CPU runs slower to save energy, so the same work shows as higher CPU."))
        }

        // Busy right now, and is that unusual?
        if load >= 70 {
            out.append(Insight(id: "busy", tone: .critical, symbol: "flame.fill",
                               title: "\(Int(load))% of all \(Int(cores)) cores are busy",
                               detail: "Your Mac is close to flat out. Apps will feel slow until this drops."))
        } else if i.recordedMinutes >= 10, i.total60m > 0, i.total1m >= 2 * i.total60m, load >= 25 {
            out.append(Insight(id: "spike", tone: .warning, symbol: "chart.line.uptrend.xyaxis",
                               title: "Busier than usual",
                               detail: "Using \(fmtCores(i.total1m)) right now, \(String(format: "%.1f", i.total1m / i.total60m))x your average over the last hour."))
        } else if load < 10 {
            out.append(Insight(id: "quiet", tone: .good, symbol: "checkmark.seal.fill",
                               title: "All quiet",
                               detail: String(format: "Only %.1f of %d cores in use. Nothing needs attention.", i.total1m / 100, Int(cores))))
        }

        // Sustained hogs: hot for the whole last 15 minutes, not a passing spike.
        if i.recordedMinutes >= 5 {
            let hogs = i.samples
                .compactMap { s -> (ProcessSample, Double)? in
                    guard let a = i.avg15m[s.pid], a >= 50 else { return nil }
                    return (s, a)
                }
                .sorted { $0.1 > $1.1 }
            for (s, a) in hogs.prefix(2) {
                let span = i.recordedMinutes >= 15 ? "15 minutes" : "\(Int(i.recordedMinutes)) minutes"
                let why = ProcessGuide.note(for: s.name).map { " \($0.headline)." } ?? ""
                out.append(Insight(id: "hog-\(s.pid)", tone: a >= 100 ? .critical : .warning, symbol: "tortoise.fill",
                                   title: "\(s.displayName) has averaged \(Int(a))% for \(span)",
                                   detail: "That is sustained, not a spike.\(why)"))
            }
        }

        // Explain the unfamiliar: a busy process whose name means nothing to most people.
        let explained = Set(out.compactMap { $0.id.hasPrefix("hog-") ? $0.id : nil })
        for s in i.samples.sorted(by: { $0.cpu > $1.cpu }).prefix(8) where s.cpu >= 20 {
            guard !explained.contains("hog-\(s.pid)"), s.name != "WindowServer", let n = ProcessGuide.note(for: s.name),
                  n.verdict != .yours else { continue }
            out.append(Insight(id: "why-\(s.name)", tone: .info, symbol: "questionmark.bubble.fill",
                               title: "\(s.name) (\(Int(s.cpu))%): \(n.headline)",
                               detail: n.detail))
            if out.filter({ $0.id.hasPrefix("why-") }).count >= 2 { break }
        }

        // WindowServer is busy because something keeps capturing the screen.
        let capturers: Set<String> = ["screencapture", "screencaptureui", "replayd", "SkyComputerUseService",
                                      "Codex Computer Use", "ScreenSharingAgent", "screensharingd"]
        if let ws = i.samples.first(where: { $0.name == "WindowServer" }), ws.cpu >= 20 {
            let active = Set(i.samples.filter { capturers.contains($0.name) && $0.cpu >= 0.5 }.map(\.name)).sorted()
            if !active.isEmpty {
                out.append(Insight(id: "ws-capture", tone: .warning, symbol: "camera.viewfinder",
                                   title: "WindowServer (\(Int(ws.cpu))%) is busy because the screen is being captured",
                                   detail: "\(active.joined(separator: ", ")) \(active.count == 1 ? "is" : "are") grabbing the screen, and every capture makes WindowServer render a fresh frame. Stop the recording, screen share or computer-use agent and it should drop."))
            } else {
                out.append(Insight(id: "ws", tone: .info, symbol: "display.2",
                                   title: "WindowServer is at \(Int(ws.cpu))%",
                                   detail: "Usually displays: a scaled resolution on an external monitor, 120 Hz, many open windows, transparency or animated content. Try System Settings > Accessibility > Display > Reduce transparency, and close windows playing video."))
            }
        }

        // Many copies of one thing add up unnoticed.
        let byName = Dictionary(grouping: i.samples) { $0.isChromeRenderer ? "Chrome tab" : $0.name }
        if let (name, group) = byName
            .filter({ $0.value.count >= 3 })
            .max(by: { $0.value.reduce(0) { $0 + $1.cpu } < $1.value.reduce(0) { $0 + $1.cpu } }) {
            let sum = group.reduce(0) { $0 + $1.cpu }
            if sum >= 15 {
                out.append(Insight(id: "many-\(name)", tone: .info, symbol: "square.stack.3d.up.fill",
                                   title: "\(group.count) \(name) processes use \(Int(sum))% together",
                                   detail: "No single one stands out, but together they are \(fmtCores(sum)). Close the ones you no longer need."))
            }
        }

        // The day so far: who dominated, when was the peak, how much is macOS itself.
        let dayTotal = i.daily.reduce(0) { $0 + $1.coreSeconds }
        if i.dailySampled >= 1800, dayTotal > 0, let top = i.daily.first {
            let share = top.coreSeconds / dayTotal * 100
            out.append(Insight(id: "top24", tone: share >= 40 ? .warning : .info, symbol: "crown.fill",
                               title: "\(top.name) used \(Int(share))% of all CPU time today",
                               detail: "\(duration(top.coreSeconds)) of CPU time over the last \(duration(i.dailySampled)) recorded, averaging \(String(format: "%.0f", top.average))%."))
            let system = i.daily.filter { AppIdentity.isSystem($0.key) }.reduce(0) { $0 + $1.coreSeconds }
            let sysShare = system / dayTotal * 100
            out.append(Insight(id: "split", tone: .info, symbol: "applelogo",
                               title: "macOS itself: \(Int(sysShare))% of CPU time, your apps: \(100 - Int(sysShare))%",
                               detail: sysShare >= 50
                                   ? "Background system work outweighs your apps today: indexing, Photos analysis, syncing. It usually settles after a day or two."
                                   : "Most CPU time goes to the apps and tools you run."))
        }
        if let (idx, peak) = i.totalHourly.enumerated().max(by: { $0.element < $1.element }), peak > 0,
           i.hourStarts.indices.contains(idx), i.dailySampled >= 3600 {
            let start = i.hourStarts[idx]
            let label = start.formatted(date: .omitted, time: .shortened)
            out.append(Insight(id: "peakhour", tone: .info, symbol: "clock.fill",
                               title: "Busiest hour: \(label), averaging \(fmtCores(peak))",
                               detail: "\(Int(peak / cores))% of the whole machine across that hour."))
        }

        // Repeat offenders deserve a rule rather than another notification.
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let flagged = Dictionary(grouping: i.events.filter { $0.date > weekAgo && $0.kind == .flagged }, by: \.name)
        if let (name, list) = flagged.max(by: { $0.value.count < $1.value.count }), list.count >= 3 {
            out.append(Insight(id: "repeat-\(name)", tone: .warning, symbol: "arrow.triangle.2.circlepath",
                               title: "\(name) was flagged \(list.count) times this week",
                               detail: "Set a rule for it on the Processes tab: auto-kill if you never want it, or ignore if it is expected."))
        }
        if let failed = i.events.last(where: { $0.kind == .killFailed && $0.date > now.addingTimeInterval(-86_400) }) {
            out.append(Insight(id: "failed-\(failed.name)", tone: .warning, symbol: "xmark.shield.fill",
                               title: "\(failed.name) survived a kill",
                               detail: "It ignored the polite stop signal. Only a force kill (kill -9) would stop it\(failed.name == "WindowServer" ? ", which logs you out" : "")."))
        }

        return out.map { enrich($0, i) }.sorted { $0.tone > $1.tone }
    }

    /// What screen-capturing processes are, in words.
    static let captureAbout: [String: String] = [
        "SkyComputerUseService": "An AI computer-use agent (Sky, now part of ChatGPT). It takes screenshots of your screen so the AI can see it, often several a second while it works.",
        "Codex Computer Use": "OpenAI Codex's computer-use helper. Screenshots the screen so Codex can see and click.",
        "replayd": "macOS's screen recording service. Busy while any app records, streams or shares the screen.",
        "screencapture": "macOS's screenshot command. A copy that keeps reappearing means some app is taking screenshots in a loop; \"started by\" shows which.",
        "screencaptureui": "The screenshot toolbar and recording overlay (Cmd-Shift-5).",
        "ScreenSharingAgent": "Screen Sharing: someone is viewing or controlling this Mac.",
        "screensharingd": "The Screen Sharing server: a remote session is connected.",
    ]

    static let captureNames = Set(captureAbout.keys)

    private static func related(_ s: ProcessSample, _ i: InsightInput, about: String? = nil) -> Insight.Related {
        Insight.Related(sample: s, about: about ?? ProcessGuide.note(for: s.name)?.headline, parent: i.parents[s.pid])
    }

    /// Adds the longer story, the processes involved and the steps to every insight.
    static func enrich(_ insight: Insight, _ i: InsightInput) -> Insight {
        var x = insight
        let byCPU = i.samples.sorted { $0.cpu > $1.cpu }
        func pid(_ prefix: String) -> Int32? { Int32(x.id.dropFirst(prefix.count)) }
        switch x.id {
        case "ws-capture":
            let ws = i.samples.filter { $0.name == "WindowServer" }
            let caps = byCPU.filter { captureNames.contains($0.name) && $0.cpu >= 0.5 }
            x.why = "WindowServer is the part of macOS that composites every window into the image on your displays. Normally it only redraws what changes. A screen capture asks it for a complete, fresh copy of the whole screen, at full Retina resolution, every time. A recorder or an AI agent doing that several times a second keeps WindowServer working even when nothing on screen is moving, and the cost grows with the number and resolution of your displays."
            x.related = ws.map { related($0, i, about: "Composites everything you see. Its CPU is the cost of the captures below.") }
                + caps.map { related($0, i, about: captureAbout[$0.name]) }
            x.steps = [
                "Stop any screen recording: look for the stop button in the menu bar, or press Cmd-Shift-5 and stop it.",
                "Pause or quit AI computer-use agents (ChatGPT or Codex computer use, Sky) when you are not using them. Idle, they may still screenshot.",
                "End Screen Sharing or remote support sessions you no longer need.",
                "Review System Settings > Privacy & Security > Screen & System Audio Recording and switch off apps that should not be capturing.",
                "If screencapture keeps coming back, quit the app shown as \"started by\".",
            ]
        case "ws":
            x.related = i.samples.filter { $0.name == "WindowServer" }.map { related($0, i) }
            x.why = "WindowServer redraws whatever changes on any display. Its load scales with pixels times refresh rate: a 5K or scaled \"looks like\" resolution on an external display renders far more pixels than it shows, and 120 Hz doubles the work of 60 Hz. Transparency, blur, animated wallpapers, video and many visible windows all add to it."
            x.steps = [
                "System Settings > Accessibility > Display: turn on Reduce transparency and Reduce motion.",
                "System Settings > Displays: use the display's native (\"Default\") resolution rather than a scaled one, and 60 Hz if you do not need 120.",
                "Close or minimise windows playing video or animations, including browser tabs.",
                "Disconnect a display you are not using.",
            ]
        case "thermal":
            x.why = "When the chip gets too hot, macOS lowers its clock speed and parks work under kernel_task to slow everything down. Every app takes longer, which makes CPU figures look higher for the same work. It is a symptom of sustained load or poor cooling, not a fault in kernel_task."
            x.related = byCPU.prefix(5).map { related($0, i) }
            x.steps = [
                "Stop or quit the heaviest processes below.",
                "Put the Mac on a hard, flat surface; keep vents clear.",
                "Check Trends for what has been heavy for the last hours.",
                "If it happens at low load, have the fans and thermal paste checked.",
            ]
        case "lowpower":
            x.steps = ["Turn it off in System Settings > Battery > Low Power Mode when plugged in and you need speed."]
        case "busy", "spike":
            x.why = "Percentages here are of the whole Mac: 100% means every core is busy. Above about 70% apps start waiting for each other and the Mac feels sluggish."
            x.related = byCPU.prefix(5).map { related($0, i) }
            x.steps = ["Look at the processes below; the top one or two usually account for most of it.", "Use Explain on any you do not recognise.", "Quit or kill what you do not need, or set a rule on the Processes tab."]
        case _ where x.id.hasPrefix("hog-"):
            if let p = pid("hog-"), let s = i.samples.first(where: { $0.pid == p }) {
                x.related = [related(s, i)]
                x.why = ProcessGuide.note(for: s.name)?.detail
                    ?? "It has stayed busy for the whole window rather than spiking, which usually means a long job, a loop, or something stuck."
                x.steps = ["Check it is doing something you expect (a build, an export, a sync).", "If not, quit it from its app, or Kill it here.", "If it does this often, set Auto-kill or Ignore on the Processes tab."]
            }
        case _ where x.id.hasPrefix("why-"):
            let name = String(x.id.dropFirst(4))
            x.related = i.samples.filter { $0.name == name }.map { related($0, i) }
            if let n = ProcessGuide.note(for: name) {
                switch n.verdict {
                case .wait: x.steps = ["Leave it: this finishes on its own.", "Keeping the Mac plugged in and awake lets it finish sooner.", "If it is still busy after a day, use Explain for specific fixes."]
                case .safe: x.steps = ["It is safe to kill; macOS restarts it when needed.", "If it comes straight back busy, use Explain for the cause."]
                case .avoid: x.steps = ["Do not kill it; find what is making it busy instead.", "Use Explain for the usual causes."]
                case .yours: x.steps = ["Quit it from its app if you do not need it now."]
                }
            }
        case _ where x.id.hasPrefix("many-"):
            let name = String(x.id.dropFirst(5))
            x.related = byCPU.filter { (name == "Chrome tab" ? $0.isChromeRenderer : $0.name == name) }.prefix(6).map { related($0, i) }
            x.why = "Each copy is small, so none stands out in a top-10 list, but they share the same cores."
            x.steps = name == "Chrome tab"
                ? ["Close tabs you are not using; background tabs with video, ads or live dashboards cost the most.", "Chrome's Window > Task Manager shows which tab is which process."]
                : ["Close the sessions or windows you no longer need.", "Check none of them is stuck in a loop: compare their 15 minute averages on the Processes tab."]
        case "top24", "split", "peakhour":
            x.steps = ["Open the Trends tab for the hour-by-hour breakdown and the full ranking."]
        case _ where x.id.hasPrefix("repeat-"):
            x.steps = ["Find it on the Processes tab and right-click to set a rule.", "Auto-kill if you never want it running hot; Ignore if it is expected (for example a nightly build)."]
        case _ where x.id.hasPrefix("failed-"):
            x.why = "A kill first sends SIGTERM, a polite request to exit. Some system processes ignore it on purpose. SIGKILL (kill -9) cannot be ignored, but stopping a core process that way takes down what depends on it."
            x.steps = ["Usually better: find what is making it busy, using Explain.", "If you must, run sudo kill -9 <pid> in Terminal, after saving your work."]
        default: break
        }
        return x
    }

    /// "2.3 cores" or "45% of a core".
    public static func fmtCores(_ percent: Double) -> String {
        percent >= 100 ? String(format: "%.1f cores", percent / 100) : "\(Int(percent))% of a core"
    }

    public static func duration(_ d: TimeInterval) -> String {
        let m = Int(d) / 60
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return m > 0 ? "\(m)m" : "\(Int(d))s"
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
