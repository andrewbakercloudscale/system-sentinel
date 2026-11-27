import Foundation

/// What this Mac has been asked to do over the kept history (up to 28 days), and which
/// MacBook would suit it: a Budget pick (the least that fits) and a Gold Plated one (room to
/// grow for four or five years).
///
/// Apple silicon memory and SSD cannot be upgraded after purchase, so "does it need more
/// memory or disk" is answered as what to order with the next Mac, and whether this one is
/// short today.
public enum DeviceAdvisor {

    /// Kinds of work that change the answer beyond raw CPU and memory figures.
    public enum Kind: String, CaseIterable, Sendable, Comparable {
        case virtualMachines = "Virtual machines and containers"
        case video = "Video editing"
        case graphics = "3D, games and design"
        case localAI = "Local AI models"
        case development = "Software development"
        case audio = "Music production"

        public static func < (a: Kind, b: Kind) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }

        /// Whole words in an app or program name that mark the kind.
        var words: [String] {
            switch self {
            case .virtualMachines: return ["parallels", "vmware", "utm", "qemu", "virtualbox", "docker", "orbstack", "colima", "lima", "virtualization", "podman"]
            case .video: return ["final cut", "premiere", "davinci", "resolve", "after effects", "compressor", "handbrake", "ffmpeg", "obs", "motion"]
            case .graphics: return ["blender", "cinema 4d", "unity", "unreal", "maya", "houdini", "photoshop", "lightroom", "illustrator", "affinity", "steam"]
            case .localAI: return ["ollama", "lm studio", "llama", "mlx", "draw things", "diffusionbee", "jan"]
            case .development: return ["xcode", "swift-frontend", "swift-build", "clang", "rustc", "cargo", "gradle", "java", "node", "android studio", "intellij", "pycharm", "webstorm", "cursor", "visual studio code", "code helper"]
            case .audio: return ["logic pro", "ableton", "pro tools", "garageband", "cubase", "reaper"]
            }
        }

        /// Wants a Pro-class chip and fans even when the averages look modest: renders and
        /// exports run flat out for minutes at a time.
        var sustained: Bool { self == .video || self == .graphics || self == .localAI }
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
        /// Memory in use plus swap: a busy minute (95th percentile) and the most seen.
        public var memoryNeed: UInt64
        public var memoryPeak: UInt64
        /// Share of minutes macOS reported memory pressure (warning or critical).
        public var pressureShare: Double
        /// Share of the time on battery. nil without power readings (a desktop Mac).
        public var batteryShare: Double?
        public var kinds: [Kind]
        /// The apps that put the kinds there, for the reasons.
        public var kindApps: [Kind: String]

        public init(days: Double, cores: Int, memory: UInt64, disk: UInt64, diskUsed: UInt64, diskGrowthPerDay: Double?,
                    cpuTypical: Double, cpuBusy: Double, cpuPeak: Double, memoryNeed: UInt64, memoryPeak: UInt64,
                    pressureShare: Double, batteryShare: Double?, kinds: [Kind] = [], kindApps: [Kind: String] = [:]) {
            self.days = days; self.cores = cores; self.memory = memory; self.disk = disk; self.diskUsed = diskUsed
            self.diskGrowthPerDay = diskGrowthPerDay; self.cpuTypical = cpuTypical; self.cpuBusy = cpuBusy
            self.cpuPeak = cpuPeak; self.memoryNeed = memoryNeed; self.memoryPeak = memoryPeak
            self.pressureShare = pressureShare; self.batteryShare = batteryShare; self.kinds = kinds; self.kindApps = kindApps
        }
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
        let sustained = w.kinds.filter(\.sustained)
        let short = w.pressureShare >= shortOfMemory

        // Budget: the least that does today's work as well as this Mac does it, or better
        // where this one is short.
        var budgetRung = 0
        var budgetWhy: [String] = []
        if w.cpuBusy >= 7 {
            budgetRung = 2
            budgetWhy.append(String(format: "Busy hours keep %.0f cores working: a Pro chip has the cores to spare.", w.cpuBusy))
        } else if !sustained.isEmpty || w.cpuBusy >= 5 {
            budgetRung = 1
            budgetWhy.append(!sustained.isEmpty
                ? "\(names(sustained, w)) run flat out for minutes: a MacBook Pro's fans keep it at full speed, where the fanless Air slows down."
                : String(format: "Busy hours keep %.0f cores working: a MacBook Pro's fans hold full speed, where the fanless Air slows down.", w.cpuBusy))
        } else {
            budgetWhy.append(String(format: "The M5 handles this: a busy hour keeps %.1f cores working.", w.cpuBusy))
        }
        // Memory macOS fills is not memory the work needs: what matters is whether it ran
        // short. Not short: what busy minutes used. Short: a step above this Mac.
        let budgetMem = short ? max(needGB, ram) * 1.25 : needGB
        let budget = pick(rung: budgetRung, large: large, memoryGB: budgetMem, storageGB: (usedGB + growth * 730 / gb) * 1.3)
        budgetWhy.append(short
            ? String(format: "%d GB memory: this Mac's %.0f GB ran low %.0f%% of the time.", budget.memoryGB, ram, w.pressureShare * 100)
            : String(format: "%d GB memory: busy minutes use %.0f GB and memory rarely ran low.", budget.memoryGB, needGB))
        budgetWhy.append(storageReason(budget.storageGB, usedGB: usedGB, growth: growth, years: 2))

        // Gold Plated: one step up in chip and in memory, and four years of disk growth.
        // The Max chip only for work that uses it.
        let wantsMax = sustained.contains { $0 == .video || $0 == .localAI || $0 == .graphics }
        var goldRung = wantsMax ? 3 : min(budget.model.rung + 1, 2)
        // A step up in memory too: when the model tops out at the budget's memory, the next chip.
        while goldRung < 3, !(lineUp.first { $0.large == large && $0.rung >= goldRung }?.memory.contains { $0.gb > budget.memoryGB } ?? true) {
            goldRung += 1
        }
        var goldWhy: [String] = []
        switch goldRung {
        case 3: goldWhy.append("The Max chip doubles the graphics cores and memory speed for \(names(sustained, w).lowercased()).")
        case 2: goldWhy.append("The Pro chip has more performance cores and faster memory: builds and exports finish sooner.")
        default: goldWhy.append("MacBook Pro: fans for full speed under load, a brighter 120 Hz screen and longer battery life.")
        }
        let goldModel = lineUp.first { $0.large == large && $0.rung >= goldRung } ?? lineUp.last!
        let goldMem = goldModel.memory.first { $0.gb > budget.memoryGB }.map { Double($0.gb) } ?? Double(budget.memoryGB)
        let gold = pick(rung: goldRung, large: large, memoryGB: goldMem, storageGB: (usedGB + growth * 1460 / gb) * 1.5)
        goldWhy.append(String(format: "%d GB memory: a step above what it needs today, for the next four years of bigger apps.", gold.memoryGB))
        goldWhy.append(storageReason(gold.storageGB, usedGB: usedGB, growth: growth, years: 4))

        var b = budget; b.reasons = budgetWhy
        var g = gold; g.reasons = goldWhy
        return Advice(budget: b, gold: g, verdict: verdict(w))
    }

    static func names(_ kinds: [Kind], _ w: Workload) -> String {
        let list = kinds.map { k in w.kindApps[k].map { "\(k.rawValue) (\($0))" } ?? k.rawValue }
        return list.joined(separator: " and ")
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
    static func pick(rung: Int, large: Bool, memoryGB: Double, storageGB: Double) -> Pick {
        for m in lineUp where m.rung >= rung && m.large == large {
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
        return Verdict(memory: memTone, memoryText: memText, disk: diskTone, diskText: diskText, cpu: cpuTone, cpuText: cpuText)
    }

    // MARK: Building the workload

    /// The value below which `p` of the values fall.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * p).rounded())))]
    }

    /// The kinds of work in a list of (app name, share of the work) pairs: an app counts once
    /// it does at least `minShare` of it.
    public static func kinds(in apps: [(name: String, share: Double)], minShare: Double = 0.05) -> [Kind: String] {
        var out: [Kind: String] = [:]
        for a in apps where a.share >= minShare {
            let n = " " + a.name.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: ".", with: " ") + " "
            for k in Kind.allCases where out[k] == nil {
                if k.words.contains(where: { n.contains(" " + $0.replacingOccurrences(of: "-", with: " ") + " ") }) { out[k] = a.name }
            }
        }
        return out
    }
}
