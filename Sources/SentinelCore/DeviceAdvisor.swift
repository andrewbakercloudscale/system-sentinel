import Foundation

/// What this Mac has been asked to do over the kept history (up to 28 days), and which
/// MacBook would suit it: a Budget pick (the least that fits) and a Gold Plated one (room to
/// grow for four or five years).
///
/// Apple silicon memory and SSD cannot be upgraded after purchase, so "does it need more
/// memory or disk" is answered as what to order with the next Mac, and whether this one is
/// short today.
public enum DeviceAdvisor {

    /// The kind of user the apps say this is. Each brings what it asks of a Mac, beyond the
    /// CPU, graphics and memory figures measured.
    public enum Profile: String, CaseIterable, Sendable, Comparable {
        case ai = "AI Engineer"
        case video = "Video Creator"
        case threeD = "3D and Games"
        case data = "Data Engineer"
        case devops = "DevOps and Cloud Engineer"
        case cyber = "Cyber Security Engineer"
        case software = "Software Engineer"
        case designer = "Designer"
        case music = "Music Producer"
        case meetings = "Meetings and Chat"
        case office = "Office User"
        case browser = "Browser User"

        public static func < (a: Profile, b: Profile) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }

        /// Whole words in an app or program name that mark the profile.
        var words: [String] {
            switch self {
            case .ai: return ["ollama", "lm studio", "lmstudio", "llama", "llama server", "mlx", "draw things", "diffusionbee", "comfyui", "jan", "gpt4all", "msty"]
            case .video: return ["final cut", "final cut pro", "premiere", "davinci", "resolve", "after effects", "compressor", "handbrake", "ffmpeg", "obs", "motion", "capcut", "screenflow"]
            case .threeD: return ["blender", "cinema 4d", "unity", "unreal", "maya", "houdini", "steam", "crossover", "whisky", "battle net", "minecraft", "zbrush", "sketchup"]
            case .data: return ["python", "python3", "jupyter", "jupyterlab", "rstudio", "r", "dbeaver", "datagrip", "tableau", "postgres", "mysqld", "duckdb", "spark", "anaconda", "spyder", "snowsql", "power bi"]
            case .devops: return ["docker", "orbstack", "colima", "lima", "podman", "kubectl", "k9s", "terraform", "vagrant", "parallels", "vmware", "utm", "qemu", "virtualbox", "virtualization", "aws", "gcloud", "az", "ansible", "kind", "minikube"]
            case .cyber: return ["wireshark", "nmap", "burp suite", "burp", "metasploit", "msfconsole", "ghidra", "hopper", "ida", "hashcat", "john", "zap", "tcpdump", "frida", "maltego", "nessus", "hydra", "sqlmap", "radare2", "binary ninja"]
            case .software: return ["xcode", "swift frontend", "swift build", "swift", "clang", "rustc", "cargo", "go", "gopls", "gradle", "java", "node", "npm", "bun", "deno", "android studio", "intellij", "intellij idea", "pycharm", "webstorm", "goland", "rider", "cursor", "visual studio code", "code", "code helper", "zed", "sublime text", "claude", "codex", "git", "simulator"]
            case .designer: return ["figma", "sketch", "photoshop", "illustrator", "lightroom", "indesign", "affinity", "affinity photo", "affinity designer", "pixelmator", "canva", "framer", "capture one"]
            case .music: return ["logic pro", "ableton", "ableton live", "pro tools", "garageband", "cubase", "reaper", "fl studio", "mainstage"]
            case .meetings: return ["zoom", "zoom us", "microsoft teams", "teams", "webex", "slack", "discord", "facetime", "whatsapp", "signal", "google meet"]
            case .office: return ["microsoft word", "microsoft excel", "microsoft powerpoint", "microsoft outlook", "word", "excel", "powerpoint", "outlook", "onenote", "keynote", "pages", "numbers", "mail", "notion", "acrobat", "adobe acrobat"]
            case .browser: return ["google chrome", "chrome", "safari", "firefox", "microsoft edge", "edge", "arc", "brave browser", "brave", "opera", "vivaldi", "chromium"]
            }
        }

        public var symbol: String {
            switch self {
            case .ai: return "brain"
            case .video: return "film"
            case .threeD: return "cube.transparent"
            case .data: return "tablecells"
            case .devops: return "server.rack"
            case .cyber: return "lock.shield"
            case .software: return "chevron.left.forwardslash.chevron.right"
            case .designer: return "paintbrush.pointed"
            case .music: return "music.note"
            case .meetings: return "video"
            case .office: return "doc.text"
            case .browser: return "globe"
            }
        }

        /// What this kind of work asks of a Mac, in a line.
        public var needs: String {
            switch self {
            case .ai: return "Local models live in memory and run on the graphics chip: memory size and graphics cores matter most."
            case .video: return "Exports and effects run the graphics chip and media engines flat out for minutes: fans and a Pro or Max chip."
            case .threeD: return "Renders and games keep the graphics chip busy for long stretches: fans and graphics cores."
            case .data: return "Notebooks and local databases hold whole datasets in memory: memory first, then cores."
            case .devops: return "Containers and virtual machines each take a slice of memory for as long as they run."
            case .cyber: return "Captures, scanners and lab virtual machines: memory for the VMs and disk for the captures."
            case .software: return "Builds use every core in bursts; the editor, simulators and browsers hold memory."
            case .designer: return "Large images and design files want memory and a good screen more than raw cores."
            case .music: return "Many tracks and plug-ins in real time: steady cores and memory for sample libraries."
            case .meetings: return "Calls use the camera, media engine and network; light on the chip, steady on battery."
            case .office: return "Documents, mail and spreadsheets: light work an Air handles easily."
            case .browser: return "Tabs are the workload: memory decides how many stay open without reloading."
            }
        }

        /// Runs flat out for minutes at a time: a Pro chip with fans, whatever the averages say.
        var sustained: Bool { self == .video || self == .threeD || self == .ai }
        /// Uses the Max chip's extra graphics cores and memory bandwidth.
        var wantsMax: Bool { sustained }
    }

    /// A profile seen, with its share of this Mac's work and the apps behind it.
    public struct ProfileShare: Equatable, Sendable {
        public var profile: Profile
        /// Share of the work of the apps that were sorted into a profile, 0 to 1.
        public var share: Double
        public var apps: [String]
        public init(profile: Profile, share: Double, apps: [String]) {
            self.profile = profile; self.share = share; self.apps = apps
        }
    }

    public struct Workload: Equatable, Sendable {
        /// Days of history behind the figures.
        public var days: Double
        public var cores: Int
        public var memory: UInt64
        public var disk: UInt64
        public var diskUsed: UInt64
        /// Bytes a day the disk is filling (negative when it is emptying). nil under a day of readings.
        public var diskGrowthPerDay: Double?
        /// CPU in cores busy: the middle hour, a busy hour (95th percentile) and the busiest.
        public var cpuTypical: Double
        public var cpuBusy: Double
        public var cpuPeak: Double
        /// Memory in use: a busy minute (95th percentile) and the most seen.
        public var memoryNeed: UInt64
        public var memoryPeak: UInt64
        /// Share of minutes macOS reported memory pressure (warning or critical).
        public var pressureShare: Double
        /// Graphics chip busy, in percent: the middle hour, a busy hour (95th percentile) and
        /// the highest reading. nil until there is graphics history.
        public var gpuTypical: Double?
        public var gpuBusy: Double?
        public var gpuPeak: Double?
        /// Hours of graphics history behind those figures.
        public var gpuHours: Double
        /// Biggest first.
        public var profiles: [ProfileShare]

        public init(days: Double, cores: Int, memory: UInt64, disk: UInt64, diskUsed: UInt64, diskGrowthPerDay: Double?,
                    cpuTypical: Double, cpuBusy: Double, cpuPeak: Double, memoryNeed: UInt64, memoryPeak: UInt64,
                    pressureShare: Double, gpuTypical: Double? = nil, gpuBusy: Double? = nil, gpuPeak: Double? = nil,
                    gpuHours: Double = 0, profiles: [ProfileShare] = []) {
            self.days = days; self.cores = cores; self.memory = memory; self.disk = disk; self.diskUsed = diskUsed
            self.diskGrowthPerDay = diskGrowthPerDay; self.cpuTypical = cpuTypical; self.cpuBusy = cpuBusy
            self.cpuPeak = cpuPeak; self.memoryNeed = memoryNeed; self.memoryPeak = memoryPeak
            self.pressureShare = pressureShare; self.gpuTypical = gpuTypical; self.gpuBusy = gpuBusy
            self.gpuPeak = gpuPeak; self.gpuHours = gpuHours; self.profiles = profiles
        }

        /// Profiles doing at least a tenth of the work: the ones that should shape the pick.
        public var main: [Profile] { profiles.filter { $0.share >= 0.1 }.map(\.profile) }
    }

    /// One MacBook in Apple's line-up, with its memory and SSD choices and what each adds to
    /// the price. Option prices are Apple's usual steps, so the totals are estimates.
    public struct MacModel: Equatable, Sendable {
        public var name: String
        public var chip: String
        /// 0 Air, 1 Pro with the base chip, 2 Pro chip, 3 Max chip.
        public var rung: Int
        /// 15 or 16-inch, rather than 13 or 14.
        public var large: Bool
        public var basePrice: Int
        public var memory: [(gb: Int, add: Int)]
        public var storage: [(gb: Int, add: Int)]

        public static func == (a: MacModel, b: MacModel) -> Bool { a.name == b.name && a.chip == b.chip }
    }

    /// Apple's US prices before tax, November 2026. Update here when the line-up changes.
    public static let lineUpDate = "November 2026"
    static let airMemory = [(16, 0), (24, 200), (32, 400)]
    static let airStorage = [(512, 0), (1024, 200), (2048, 600), (4096, 1200)]
    static let proMemory = [(24, 0), (48, 400), (64, 600)]
    static let proStorage = [(1024, 0), (2048, 400), (4096, 1000), (8192, 2200)]
    static let maxMemory = [(36, 0), (64, 600), (128, 1600)]
    static let maxStorage = [(2048, 0), (4096, 600), (8192, 1800)]
    public static let lineUp: [MacModel] = [
        // The entry MacBook: an iPhone chip and 8 GB that cannot be raised. Listed first so light
        // work that fits in 8 GB is offered it.
        MacModel(name: "MacBook Neo", chip: "A18 Pro", rung: 0, large: false, basePrice: 599,
                 memory: [(8, 0)], storage: [(256, 0), (512, 100)]),
        MacModel(name: "MacBook Air 13-inch", chip: "M5", rung: 0, large: false, basePrice: 1099, memory: airMemory, storage: airStorage),
        MacModel(name: "MacBook Pro 14-inch", chip: "M5", rung: 1, large: false, basePrice: 1699,
                 memory: airMemory, storage: [(1024, 0), (2048, 400), (4096, 1000)]),
        MacModel(name: "MacBook Pro 14-inch", chip: "M5 Pro", rung: 2, large: false, basePrice: 2199, memory: proMemory, storage: proStorage),
        MacModel(name: "MacBook Pro 14-inch", chip: "M5 Max", rung: 3, large: false, basePrice: 3599, memory: maxMemory, storage: maxStorage),
        MacModel(name: "MacBook Air 15-inch", chip: "M5", rung: 0, large: true, basePrice: 1299, memory: airMemory, storage: airStorage),
        // No 16-inch with the base chip: a large screen and fans start at the Pro chip.
        MacModel(name: "MacBook Pro 16-inch", chip: "M5 Pro", rung: 2, large: true, basePrice: 2699, memory: proMemory, storage: proStorage),
        MacModel(name: "MacBook Pro 16-inch", chip: "M5 Max", rung: 3, large: true, basePrice: 3899, memory: maxMemory, storage: maxStorage),
    ]

    public struct Pick: Equatable, Sendable {
        public var model: MacModel
        public var memoryGB: Int
        public var storageGB: Int
        public var price: Int
        public var reasons: [String]
    }

    /// How this Mac stands up today.
    public struct Verdict: Equatable, Sendable {
        public enum Tone: Int, Sendable { case good, tight, short }
        public var memory: Tone
        public var memoryText: String
        public var disk: Tone
        public var diskText: String
        public var cpu: Tone
        public var cpuText: String
        public var gpu: Tone
        public var gpuText: String?
    }

    public struct Advice: Equatable, Sendable {
        public var budget: Pick
        public var gold: Pick
        public var verdict: Verdict
    }

    /// Days of history wanted before advising at all.
    public static let minimumDays = 2.0

    static let gb = 1_073_741_824.0

    /// Memory ran low this share of the time or more: the next Mac needs more than this one.
    static let shortOfMemory = 0.05

    /// `large` picks 15 and 16-inch models, else 13 and 14-inch.
    public static func advise(_ w: Workload, large: Bool = false) -> Advice? {
        guard w.days >= minimumDays else { return nil }
        let ram = Double(w.memory) / gb
        let needGB = Double(w.memoryNeed) / gb
        let growth = max(w.diskGrowthPerDay ?? 0, 0)
        let usedGB = Double(w.diskUsed) / gb
        let sustained = w.main.filter(\.sustained)
        let short = w.pressureShare >= shortOfMemory
        let gpu = w.gpuBusy ?? 0

        // Budget: the least that does today's work as well as this Mac does it, or better
        // where this one is short.
        var budgetRung = 0
        var budgetWhy: [String] = []
        if w.cpuBusy >= 7 || gpu >= 50 {
            budgetRung = 2
            budgetWhy.append(gpu >= 50
                ? String(format: "A busy hour keeps the graphics chip %.0f%% busy: the Pro chip has twice the graphics cores.", gpu)
                : String(format: "Busy hours keep %.0f cores working: a Pro chip has the cores to spare.", w.cpuBusy))
        } else if !sustained.isEmpty || w.cpuBusy >= 5 || gpu >= 25 {
            budgetRung = 1
            budgetWhy.append(!sustained.isEmpty
                ? "\(list(sustained)) work runs flat out for minutes: a MacBook Pro's fans keep it at full speed, where the fanless Air slows down."
                : gpu >= 25
                ? String(format: "A busy hour keeps the graphics chip %.0f%% busy: a MacBook Pro's fans hold full speed, where the fanless Air slows down.", gpu)
                : String(format: "Busy hours keep %.0f cores working: a MacBook Pro's fans hold full speed, where the fanless Air slows down.", w.cpuBusy))
        } else {
            budgetWhy.append(String(format: "The M5 handles this: a busy hour keeps %.1f cores working", w.cpuBusy) + gpuPart(gpu))
        }
        // Memory macOS fills is not memory the work needs: what matters is whether it ran
        // short. Not short: what busy minutes used. Short: a step above this Mac.
        let budgetMem = short ? max(needGB, ram) * 1.25 : needGB
        let budgetDisk = (usedGB + growth * 730 / gb) * 1.3
        // The Neo only for light work: six cores, and no room above 8 GB later.
        let neoFits = budgetRung == 0 && w.cpuBusy < 3 && gpu < 15 && sustained.isEmpty
        var budget = pick(rung: budgetRung, large: large, memoryGB: budgetMem, storageGB: budgetDisk, neo: neoFits)
        if budget.model.chip == "A18 Pro" {
            budgetWhy[0] = String(format: "The MacBook Neo handles this: a busy hour keeps %.1f cores working", w.cpuBusy) + gpuPart(gpu)
        }
        budgetWhy.append(short
            ? String(format: "%d GB memory: this Mac's %.0f GB ran low %.0f%% of the time.", budget.memoryGB, ram, w.pressureShare * 100)
            : String(format: "%d GB memory: busy minutes use %.0f GB and memory rarely ran low.", budget.memoryGB, needGB))
        budgetWhy.append(storageReason(budget.storageGB, usedGB: usedGB, growth: growth, years: 2))
        budget.reasons = budgetWhy

        // Gold Plated: one step up in chip and in memory, and four years of disk growth.
        // The Max chip only for work that uses it.
        let wantsMax = w.main.contains(where: \.wantsMax) || gpu >= 40
        let goldDisk = (usedGB + growth * 1460 / gb) * 1.5
        var goldWhy: [String] = []
        var gold: Pick
        if budget.model.chip == "A18 Pro" {
            // From the Neo, the Air is the step: the M5, and memory that can grow with the apps.
            gold = pick(rung: 0, large: large, memoryGB: 24, storageGB: goldDisk)
            goldWhy.append("MacBook Air: the M5 chip, a bigger battery and memory beyond the Neo's fixed 8 GB.")
        } else {
            var goldRung = wantsMax ? 3 : min(budget.model.rung + 1, 2)
            // A step up in memory too: when the model tops out at the budget's memory, the next chip.
            while goldRung < 3, !(lineUp.first { $0.large == large && $0.rung >= goldRung && $0.chip != "A18 Pro" }?.memory.contains { $0.gb > budget.memoryGB } ?? true) {
                goldRung += 1
            }
            switch goldRung {
            case 3: goldWhy.append(gpu >= 40
                ? String(format: "The Max chip has four times the M5's graphics cores: a busy hour keeps this one %.0f%% busy.", gpu)
                : "The Max chip doubles the graphics cores and memory speed for \(list(w.main.filter(\.wantsMax)).lowercased()) work.")
            case 2: goldWhy.append("The Pro chip has more performance cores, twice the graphics cores and faster memory: builds and exports finish sooner.")
            default: goldWhy.append("MacBook Pro: fans for full speed under load, a brighter 120 Hz screen and longer battery life.")
            }
            let goldModel = lineUp.first { $0.large == large && $0.rung >= goldRung && $0.chip != "A18 Pro" } ?? lineUp.last!
            let goldMem = goldModel.memory.first { $0.gb > budget.memoryGB }.map { Double($0.gb) } ?? Double(budget.memoryGB)
            gold = pick(rung: goldRung, large: large, memoryGB: goldMem, storageGB: goldDisk)
        }
        goldWhy.append(String(format: "%d GB memory: a step above what it needs today, for the next four years of bigger apps.", gold.memoryGB))
        goldWhy.append(storageReason(gold.storageGB, usedGB: usedGB, growth: growth, years: 4))
        gold.reasons = goldWhy
        return Advice(budget: budget, gold: gold, verdict: verdict(w))
    }

    static func gpuPart(_ gpu: Double) -> String {
        gpu >= 1 ? String(format: " and the graphics chip %.0f%% busy.", gpu) : " and the graphics chip barely used."
    }

    static func list(_ p: [Profile]) -> String {
        p.map(\.rawValue).joined(separator: " and ")
    }
    static func storageReason(_ gb: Int, usedGB: Double, growth: Double, years: Int) -> String {
        let size = gb >= 1024 ? "\(gb / 1024) TB" : "\(gb) GB"
        if growth / Self.gb >= 0.1 {
            return String(format: "%@ SSD: %.0f GB in use, growing about %.1f GB a day, leaves room for %d years.", size, usedGB, growth / Self.gb, years)
        }
        return String(format: "%@ SSD: %.0f GB in use with room to spare.", size, usedGB)
    }

    /// The cheapest configuration of the rung's model (or a higher one when the memory asked
    /// for is beyond it) with at least this much memory and SSD.
    static func pick(rung: Int, large: Bool, memoryGB: Double, storageGB: Double, neo: Bool = false) -> Pick {
        for m in lineUp where m.rung >= rung && m.large == large && (neo || m.chip != "A18 Pro") {
            // The Neo only when its SSD fits too: it tops out at 512 GB.
            if m.chip == "A18 Pro", !m.storage.contains(where: { Double($0.gb) >= storageGB }) { continue }
            guard let mem = m.memory.first(where: { Double($0.gb) >= memoryGB }) ?? (m.rung == 3 ? m.memory.last : nil) else { continue }
            let disk = m.storage.first(where: { Double($0.gb) >= storageGB }) ?? m.storage.last!
            return Pick(model: m, memoryGB: mem.gb, storageGB: disk.gb, price: m.basePrice + mem.add + disk.add, reasons: [])
        }
        let m = lineUp.last!
        return Pick(model: m, memoryGB: m.memory.last!.gb, storageGB: m.storage.last!.gb,
                    price: m.basePrice + m.memory.last!.add + m.storage.last!.add, reasons: [])
    }

    static func verdict(_ w: Workload) -> Verdict {
        let ram = Double(w.memory) / gb
        let need = Double(w.memoryNeed) / gb
        let memTone: Verdict.Tone = w.pressureShare >= 0.15 ? .short : w.pressureShare >= shortOfMemory ? .tight : .good
        let low = w.pressureShare >= 0.005 ? String(format: "ran low %.0f%% of the time", w.pressureShare * 100) : "never ran low"
        let memText: String
        switch memTone {
        case .short: memText = String(format: "Short: busy minutes use %.0f GB of its %.0f GB and memory %@. More memory would stop the swapping.", need, ram, low)
        case .tight: memText = String(format: "Tight: busy minutes use %.0f GB of its %.0f GB and memory %@.", need, ram, low)
        case .good: memText = String(format: "Enough: busy minutes use %.0f GB of its %.0f GB and memory %@.", need, ram, low)
        }

        let free = Double(w.disk) - Double(w.diskUsed)
        let growth = w.diskGrowthPerDay ?? 0
        let daysLeft = growth > 100 * 1_048_576 ? free / growth : nil
        let freeShare = w.disk > 0 ? free / Double(w.disk) : 1
        let diskTone: Verdict.Tone = freeShare < 0.1 || (daysLeft ?? .infinity) < 180 ? .short
            : freeShare < 0.2 || (daysLeft ?? .infinity) < 365 ? .tight : .good
        var diskText = String(format: "%@: %.0f GB free of %.0f GB", diskTone == .good ? "Enough" : diskTone == .tight ? "Tight" : "Short", free / gb, Double(w.disk) / gb)
        if let d = daysLeft { diskText += d < 730 ? String(format: ", full in about %.0f months at this pace.", d / 30) : ", growing slowly." }
        else { diskText += "." }

        let cores = Double(max(w.cores, 1))
        let cpuTone: Verdict.Tone = w.cpuBusy > cores * 0.75 ? .short : w.cpuBusy > cores * 0.5 ? .tight : .good
        let cpuText = String(format: "%@: a busy hour uses %.1f of its %d cores; typical %.1f.",
                             cpuTone == .good ? "Enough" : cpuTone == .tight ? "Busy" : "Stretched", w.cpuBusy, w.cores, w.cpuTypical)
        var gpuTone = Verdict.Tone.good
        var gpuText: String?
        if let busy = w.gpuBusy {
            gpuTone = busy >= 70 ? .short : busy >= 40 ? .tight : .good
            gpuText = String(format: "%@: a busy hour keeps the graphics chip %.0f%% busy; typical %.0f%%",
                             gpuTone == .good ? "Enough" : gpuTone == .tight ? "Busy" : "Stretched", busy, w.gpuTypical ?? 0)
            if let p = w.gpuPeak, p >= 50 { gpuText! += String(format: ", peaks at %.0f%%", p) }
            gpuText! += w.gpuHours < 24 ? (w.gpuHours < 1.5 ? " (1 hour of readings so far)." : String(format: " (%.0f hours of readings so far).", w.gpuHours)) : "."
        }
        return Verdict(memory: memTone, memoryText: memText, disk: diskTone, diskText: diskText, cpu: cpuTone, cpuText: cpuText,
                       gpu: gpuTone, gpuText: gpuText)
    }

    // MARK: Building the workload

    /// The value below which `p` of the values fall.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))]
    }

    /// The profiles in a list of (app name, share of the work) pairs. Each app counts for the
    /// first profile whose words match it; shares are then scaled to the matched work, and
    /// profiles under `minShare` of it are dropped.
    public static func profiles(in apps: [(name: String, share: Double)], minShare: Double = 0.03) -> [ProfileShare] {
        var score: [Profile: Double] = [:]
        var names: [Profile: [(String, Double)]] = [:]
        for a in apps where a.share > 0 {
            guard let p = profile(of: a.name) else { continue }
            score[p, default: 0] += a.share
            names[p, default: []].append((a.name, a.share))
        }
        let total = score.values.reduce(0, +)
        guard total > 0 else { return [] }
        return score.map { p, v in
            ProfileShare(profile: p, share: v / total,
                         apps: (names[p] ?? []).sorted { $0.1 > $1.1 }.map(\.0).reduce(into: [String]()) { list, n in
                             // "claude" beside "Claude Code" says nothing new.
                             if !list.contains(where: { $0.lowercased().contains(n.lowercased()) || n.lowercased().contains($0.lowercased()) }) { list.append(n) }
                         }.prefix(3).map { $0 })
        }
        .filter { $0.share >= minShare }
        .sorted { $0.share != $1.share ? $0.share > $1.share : $0.profile < $1.profile }
    }

    /// The profile an app's name belongs to, by whole words. Earlier profiles win: Python in
    /// a notebook is data work before it is software.
    public static func profile(of name: String) -> Profile? {
        let n = " " + name.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ") + " "
        return Profile.allCases.first { p in p.words.contains { n.contains(" " + $0 + " ") } }
    }
}
