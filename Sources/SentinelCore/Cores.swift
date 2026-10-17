import Darwin
import Foundation

/// Load on each CPU core, split into Apple silicon's performance and efficiency cores.
///
/// macOS schedules background work on the efficiency cores. Busy performance cores mean
/// foreground or heavy work, and that is what costs battery: a P core draws several times
/// what an E core does for the same time.
public struct CoreLoad: Equatable, Sendable {
    /// Busy percent per logical CPU, in the kernel's order.
    public let perCore: [Double]
    /// How many of the first CPUs are efficiency cores (0 on Intel).
    public let efficiencyCount: Int

    public init(perCore: [Double], efficiencyCount: Int) {
        self.perCore = perCore
        self.efficiencyCount = min(max(efficiencyCount, 0), perCore.count)
    }

    public var efficiency: [Double] { Array(perCore.prefix(efficiencyCount)) }
    public var performance: [Double] { Array(perCore.dropFirst(efficiencyCount)) }
    public var efficiencyAverage: Double? { Self.mean(efficiency) }
    public var performanceAverage: Double? { Self.mean(performance) }

    static func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

    /// Cumulative user, system, idle and nice ticks for one CPU.
    public struct Ticks: Equatable, Sendable {
        public var user, system, idle, nice: UInt64
        public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
            self.user = user
            self.system = system
            self.idle = idle
            self.nice = nice
        }
    }

    /// Busy share per CPU between two readings. Counters wrap at 32 bits.
    public static func between(_ a: [Ticks], _ b: [Ticks], efficiencyCount: Int) -> CoreLoad {
        let per = zip(a, b).map { x, y -> Double in
            func d(_ p: UInt64, _ q: UInt64) -> Double { Double(q >= p ? q - p : q + (1 << 32) - p) }
            let busy = d(x.user, y.user) + d(x.system, y.system) + d(x.nice, y.nice)
            let total = busy + d(x.idle, y.idle)
            return total > 0 ? busy / total * 100 : 0
        }
        return CoreLoad(perCore: per, efficiencyCount: efficiencyCount)
    }

    public static func readTicks() -> [Ticks] {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &count) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        return (0..<Int(n)).map { i in
            let b = Int(CPU_STATE_MAX) * i
            func t(_ s: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[b + Int(s)])) }
            return Ticks(user: t(CPU_STATE_USER), system: t(CPU_STATE_SYSTEM), idle: t(CPU_STATE_IDLE), nice: t(CPU_STATE_NICE))
        }
    }

    /// Efficiency cores on Apple silicon (perflevel1); the kernel lists them first.
    public static let efficiencyCores: Int = {
        var levels: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.nperflevels", &levels, &size, nil, 0) == 0, levels > 1 else { return 0 }
        var n: Int32 = 0
        size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.perflevel1.logicalcpu", &n, &size, nil, 0) == 0 ? Int(n) : 0
    }()
}

/// Keeps the last reading so each call returns load since the previous one.
public final class CoreSampler {
    private var last: [CoreLoad.Ticks] = []
    public init() {}

    public func sample() -> CoreLoad? {
        let now = CoreLoad.readTicks()
        defer { last = now }
        guard last.count == now.count, !now.isEmpty else { return nil }
        return CoreLoad.between(last, now, efficiencyCount: CoreLoad.efficiencyCores)
    }
}

/// Programs that start by themselves: launch agents and daemons. These are where
/// background CPU and battery drain usually come from, and where to switch them off.
public struct BackgroundItem: Equatable, Sendable, Identifiable {
    public enum Scope: String, Sendable {
        /// ~/Library/LaunchAgents: yours, runs while you are logged in.
        case user
        /// /Library/LaunchAgents: installed for every user.
        case allUsers
        /// /Library/LaunchDaemons: runs as root, even at the login screen.
        case system
    }

    public let label: String
    /// The program it runs, when the plist names one.
    public let program: String?
    /// What it actually runs when `program` is a shell or interpreter: the script.
    public let script: String?
    public let plist: String
    public let scope: Scope
    public let runAtLoad: Bool
    /// launchd restarts it if it exits.
    public let keepAlive: Bool
    /// Runs on a timer, in seconds.
    public let interval: Int?
    public let disabled: Bool
    public var id: String { plist }

    /// "com.google.keystone.agent" gives "Google"; best effort for the list.
    public var vendor: String {
        let parts = label.split(separator: ".")
        guard parts.count >= 2, ["com", "org", "io", "net", "us", "de", "co", "app"].contains(parts[0]) else {
            return parts.first.map(String.init) ?? label
        }
        return parts[1].prefix(1).uppercased() + parts[1].dropFirst()
    }

    public var name: String { (script ?? program).map { ($0 as NSString).lastPathComponent } ?? label }

    /// The executable path a running copy shows in ps, unless it runs through an
    /// interpreter, where every zsh or python would match.
    public var processPath: String? { script == nil && !BackgroundItems.isInterpreter(program) ? program : nil }
}

public enum BackgroundItems {
    public static let folders: [(String, BackgroundItem.Scope)] = [
        (NSString(string: "~/Library/LaunchAgents").expandingTildeInPath, .user),
        ("/Library/LaunchAgents", .allUsers),
        ("/Library/LaunchDaemons", .system),
    ]

    static let interpreters: Set<String> = ["sh", "bash", "zsh", "env", "python", "python3", "node", "ruby", "perl", "osascript"]

    public static func isInterpreter(_ program: String?) -> Bool {
        program.map { interpreters.contains(($0 as NSString).lastPathComponent) } ?? false
    }

    public static func scan() -> [BackgroundItem] {
        var out: [BackgroundItem] = []
        for (dir, scope) in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".plist") {
                let path = (dir as NSString).appendingPathComponent(f)
                guard let data = FileManager.default.contents(atPath: path),
                      let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let item = parse(dict, plist: path, scope: scope) else { continue }
                out.append(item)
            }
        }
        return out.sorted { $0.label.lowercased() < $1.label.lowercased() }
    }

    public static func parse(_ d: [String: Any], plist: String, scope: BackgroundItem.Scope) -> BackgroundItem? {
        guard let label = d["Label"] as? String else { return nil }
        let args = d["ProgramArguments"] as? [String] ?? []
        let program = (d["Program"] as? String) ?? args.first
        // "zsh -c ~/bin/x.sh" or "python3 /opt/y.py": name it after the script.
        var script: String?
        if isInterpreter(program) {
            let rest = args.dropFirst().filter { !$0.hasPrefix("-") }
            script = rest.first.map { $0.split(separator: " ").first.map(String.init) ?? $0 }
        }
        let keepAlive: Bool = {
            if let b = d["KeepAlive"] as? Bool { return b }
            return d["KeepAlive"] is [String: Any]
        }()
        return BackgroundItem(label: label, program: program, script: script, plist: plist, scope: scope,
                              runAtLoad: d["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
                              interval: (d["StartInterval"] as? NSNumber)?.intValue,
                              disabled: d["Disabled"] as? Bool ?? false)
    }
}
