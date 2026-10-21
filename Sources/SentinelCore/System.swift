import Darwin
import Foundation
import IOKit

// MARK: Memory

/// How much memory the Mac has left, as macOS itself judges it.
public struct MemoryStatus: Equatable, Sendable {
    public enum Pressure: Int, Sendable, Comparable {
        case normal, warning, critical
        public static func < (a: Pressure, b: Pressure) -> Bool { a.rawValue < b.rawValue }

        /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
        public init(level: Int) {
            switch level {
            case 4...: self = .critical
            case 2, 3: self = .warning
            default: self = .normal
            }
        }

        public var label: String {
            switch self {
            case .normal: return "Normal"
            case .warning: return "Under pressure"
            case .critical: return "Critical"
            }
        }
    }

    public var pressure: Pressure
    /// Bytes.
    public var total: UInt64
    /// What Activity Monitor calls Memory Used: app memory, wired and compressed.
    public var used: UInt64
    public var compressed: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    /// Activity Monitor's breakdown, in bytes: app memory, wired (the kernel's own, never
    /// moved), cached files macOS can drop at once, and truly free.
    public var app: UInt64 = 0
    public var wired: UInt64 = 0
    public var cached: UInt64 = 0
    public var free: UInt64 = 0
    /// What the compressed memory would take uncompressed.
    public var compressedOriginal: UInt64 = 0
    /// Bytes moved to and from the swap file since the Mac started (running counters).
    public var swapIns: UInt64 = 0
    public var swapOuts: UInt64 = 0

    public init(pressure: Pressure, total: UInt64, used: UInt64, compressed: UInt64, swapUsed: UInt64, swapTotal: UInt64) {
        self.pressure = pressure
        self.total = total
        self.used = used
        self.compressed = compressed
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
    }

    public static func read() -> MemoryStatus? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        var m = MemoryStatus(pressure: Pressure(level: Int(level)), total: ProcessInfo.processInfo.physicalMemory,
                             used: (app + wired + compressed) * page, compressed: compressed * page,
                             swapUsed: swap.xsu_used, swapTotal: swap.xsu_total)
        m.app = app * page
        m.wired = wired * page
        m.cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page
        m.free = UInt64(stats.free_count) * page
        m.compressedOriginal = UInt64(stats.total_uncompressed_pages_in_compressor) * page
        m.swapIns = UInt64(stats.swapins) * page
        m.swapOuts = UInt64(stats.swapouts) * page
        return m
    }

    /// Seconds since the Mac started. Swap only empties on a restart.
    public static func uptime(at now: Date = Date()) -> TimeInterval? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return now.timeIntervalSince1970 - Double(tv.tv_sec)
    }

    /// A process's memory as Activity Monitor counts it (its footprint), which unlike the
    /// resident size does not count shared libraries in every process. nil for processes
    /// of other users, which macOS will not describe.
    public static func footprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return r == 0 ? info.ri_phys_footprint : nil
    }

    /// The part of a process's memory that is in RAM right now. Footprint minus this is what
    /// macOS has compressed or written to swap.
    public static func resident(_ pid: Int32) -> UInt64? {
        var ti = proc_taskinfo()
        let n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
        return n > 0 ? ti.pti_resident_size : nil
    }
}

// MARK: Graphics

public enum GPUReader {
    /// The graphics chip's busy share, 0 to 100, from the driver's performance counters.
    public static func utilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let d = props?.takeRetainedValue() as? [String: Any] else { continue }
            if let u = parse(d) { best = max(best ?? 0, u) }
        }
        return best
    }

    public static func parse(_ registry: [String: Any]) -> Double? {
        guard let stats = registry["PerformanceStatistics"] as? [String: Any] else { return nil }
        let n = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber
        return n.map { min(max($0.doubleValue, 0), 100) }
    }

    /// The graphics chip now: how busy, the memory it holds and, with `perProcess`, which
    /// processes used it. Apple Silicon shares memory with the CPU, so graphics memory is
    /// part of the Mac's memory, not a separate pool.
    public struct Status: Equatable, Sendable {
        public var name: String?
        public var cores: Int?
        /// 0 to 100.
        public var busy: Double
        /// Memory the graphics driver holds right now, and has set aside, in bytes.
        public var memoryInUse: UInt64?
        public var memoryAllocated: UInt64?
        /// Total graphics time each process has used, in nanoseconds, since it started.
        public var gpuTime: [Int32: UInt64] = [:]
        /// The name each process gave when it opened the graphics chip.
        public var names: [Int32: String] = [:]

        public init(name: String? = nil, cores: Int? = nil, busy: Double, memoryInUse: UInt64? = nil, memoryAllocated: UInt64? = nil) {
            self.name = name
            self.cores = cores
            self.busy = busy
            self.memoryInUse = memoryInUse
            self.memoryAllocated = memoryAllocated
        }
    }

    /// Reads the busiest graphics chip and, through its clients, each process's graphics time.
    public static func read() -> Status? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Status?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard var s = status(properties(service)) else { continue }
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS {
                while case let child = IOIteratorNext(children), child != 0 {
                    defer { IOObjectRelease(child) }
                    guard let c = client(properties(child)) else { continue }
                    s.gpuTime[c.pid, default: 0] += c.time
                    s.names[c.pid] = c.name
                }
                IOObjectRelease(children)
            }
            if best.map({ s.busy > $0.busy || s.gpuTime.count > $0.gpuTime.count }) ?? true { best = s }
        }
        return best
    }

    private static func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return props?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    public static func status(_ registry: [String: Any]) -> Status? {
        guard let busy = parse(registry), let stats = registry["PerformanceStatistics"] as? [String: Any] else { return nil }
        let bytes = { (key: String) in (stats[key] as? NSNumber).map { $0.uint64Value } }
        return Status(name: registry["model"] as? String, cores: (registry["gpu-core-count"] as? NSNumber)?.intValue, busy: busy,
                      memoryInUse: bytes("In use system memory"), memoryAllocated: bytes("Alloc system memory"))
    }

    /// One process's connection to the graphics chip: "IOUserClientCreator" is "pid 395,
    /// WindowServer", and "AppUsage" lists its graphics time per command queue.
    public static func client(_ registry: [String: Any]) -> (pid: Int32, name: String, time: UInt64)? {
        guard let creator = registry["IOUserClientCreator"] as? String, creator.hasPrefix("pid "),
              let comma = creator.firstIndex(of: ","),
              let pid = Int32(creator[creator.index(creator.startIndex, offsetBy: 4)..<comma]) else { return nil }
        let usage = registry["AppUsage"] as? [[String: Any]] ?? []
        let time = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
        return (pid, creator[creator.index(after: comma)...].trimmingCharacters(in: .whitespaces), time)
    }

    /// Each process's share of the graphics chip between two readings, 0 to 100. Processes
    /// that are new, gone or idle are left out.
    public static func shares(from before: [Int32: UInt64], to after: [Int32: UInt64], seconds: Double) -> [Int32: Double] {
        guard seconds > 0 else { return [:] }
        var out: [Int32: Double] = [:]
        for (pid, t) in after {
            guard let b = before[pid], t > b else { continue }
            out[pid] = min(Double(t - b) / 1e9 / seconds * 100, 100)
        }
        return out
    }
}

// MARK: Network and disk

/// Running byte counters for one process.
public struct IOCounters: Equatable, Sendable {
    public var netIn: UInt64 = 0
    public var netOut: UInt64 = 0
    public var diskRead: UInt64 = 0
    public var diskWrite: UInt64 = 0
    public init(netIn: UInt64 = 0, netOut: UInt64 = 0, diskRead: UInt64 = 0, diskWrite: UInt64 = 0) {
        self.netIn = netIn
        self.netOut = netOut
        self.diskRead = diskRead
        self.diskWrite = diskWrite
    }
}

/// Bytes per second for one process.
public struct IORate: Equatable, Sendable {
    public let pid: Int32
    public let netIn, netOut, diskRead, diskWrite: Double
    public var net: Double { netIn + netOut }
    public var disk: Double { diskRead + diskWrite }
}

public enum IOSampler {
    /// Network bytes since each process started, from `nettop` (any user, no admin needed).
    public static func network() -> [Int32: (UInt64, UInt64)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        task.arguments = ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return parseNettop(String(decoding: data, as: UTF8.self))
    }

    /// Lines like `Google Chrome H.1234,5000,600,`. The name may contain dots and commas
    /// are not escaped, so the pid is what follows the last dot of the first field group.
    public static func parseNettop(_ text: String) -> [Int32: (UInt64, UInt64)] {
        var out: [Int32: (UInt64, UInt64)] = [:]
        for line in text.split(separator: "\n") {
            var f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if f.last == "" { f.removeLast() }
            guard f.count >= 3, let bout = UInt64(f[f.count - 1]), let bin = UInt64(f[f.count - 2]) else { continue }
            let ident = f[0..<(f.count - 2)].joined(separator: ",")
            guard let dot = ident.lastIndex(of: "."), let pid = Int32(ident[ident.index(after: dot)...]) else { continue }
            let prev = out[pid] ?? (0, 0)
            out[pid] = (prev.0 + bin, prev.1 + bout)
        }
        return out
    }

    /// Disk bytes since start, from the kernel. Processes of other users (root daemons)
    /// are refused by macOS and simply absent.
    public static func disk(_ pid: Int32) -> (UInt64, UInt64)? {
        var info = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return r == 0 ? (info.ri_diskio_bytesread, info.ri_diskio_byteswritten) : nil
    }
}

/// Turns running counters into rates between calls.
public final class IOTracker {
    private var last: [Int32: IOCounters] = [:]
    private var lastTime: Date?
    public init() {}

    public func update(_ counters: [Int32: IOCounters], at now: Date) -> [IORate] {
        defer {
            last = counters
            lastTime = now
        }
        guard let t = lastTime, now.timeIntervalSince(t) > 0 else { return [] }
        let span = now.timeIntervalSince(t)
        func d(_ a: UInt64, _ b: UInt64) -> Double { b >= a ? Double(b - a) / span : 0 }
        return counters.compactMap { pid, c in
            guard let p = last[pid] else { return nil }
            let r = IORate(pid: pid, netIn: d(p.netIn, c.netIn), netOut: d(p.netOut, c.netOut),
                           diskRead: d(p.diskRead, c.diskRead), diskWrite: d(p.diskWrite, c.diskWrite))
            return r.net + r.disk > 0 ? r : nil
        }
    }
}

/// Network and disk by app.
public struct IORow: Equatable, Sendable, Identifiable {
    public let key: String
    public let name: String
    public let netIn, netOut, diskRead, diskWrite: Double
    public let pids: [Int32]
    public var id: String { key }
    public var net: Double { netIn + netOut }
    public var disk: Double { diskRead + diskWrite }

    public static func group(_ rates: [IORate], processes: [ProcessSample], key: (String) -> String, name: (String) -> String) -> [IORow] {
        let paths = Dictionary(processes.map { ($0.pid, $0.path) }, uniquingKeysWith: { a, _ in a })
        var acc: [String: (Double, Double, Double, Double, [Int32])] = [:]
        for r in rates {
            guard let path = paths[r.pid] else { continue }
            let k = key(path)
            var a = acc[k] ?? (0, 0, 0, 0, [])
            a.0 += r.netIn; a.1 += r.netOut; a.2 += r.diskRead; a.3 += r.diskWrite; a.4.append(r.pid)
            acc[k] = a
        }
        return acc.map { IORow(key: $0.key, name: name($0.key), netIn: $0.value.0, netOut: $0.value.1,
                               diskRead: $0.value.2, diskWrite: $0.value.3, pids: $0.value.4.sorted()) }
            .sorted { $0.net + $0.disk > $1.net + $1.disk }
    }

    /// "1.2 MB/s".
    public static func rate(_ bytesPerSecond: Double) -> String {
        let b = bytesPerSecond
        if b >= 1_000_000 { return String(format: "%.1f MB/s", b / 1_000_000) }
        if b >= 1_000 { return String(format: "%.0f KB/s", b / 1_000) }
        return b > 0 ? "<1 KB/s" : "–"
    }
}

// MARK: Sleep log

/// One line of the power management log that matters for battery: going to sleep, a full
/// wake, or a dark wake (the Mac woke briefly with the screen off).
public struct SleepEvent: Equatable, Sendable {
    public enum Kind: String, Sendable { case sleep, wake, darkWake }
    public let date: Date
    public let kind: Kind
    /// The raw cause from the log.
    public let reason: String
    public let charge: Int?
    public let onBattery: Bool

    /// The cause in words.
    public var cause: String {
        let r = reason.lowercased()
        if kind == .sleep {
            if r.contains("clamshell") { return "lid closed" }
            if r.contains("idle") { return "idle" }
            if r.contains("low power") { return "standby" }
            if r.contains("software") || r.contains("user") { return "you chose Sleep" }
            return reason.isEmpty ? "sleep" : reason
        }
        if r.contains("lid") { return "lid opened" }
        if r.contains("useractivity") || r.contains("/user") || r.hasSuffix("user") || r.contains("hid") { return "you" }
        if r.contains("rtc") || r.contains("maintenance") { return "scheduled maintenance" }
        if r.contains("wlan") || r.contains("wifi") || r.contains("arpt") || r.contains("network") { return "network" }
        if r.contains("smc") || r.contains("ac attach") || r.contains("charger") || r.contains("power") { return "power or charger" }
        if r.contains("bluetooth") || r.contains("bt") { return "Bluetooth" }
        if r.contains("usb") || r.contains("xhc") { return "USB device" }
        if r.contains("notification") || r.contains("push") || r.contains("apsd") { return "notifications" }
        return "other"
    }
}

/// Sleep over a period: how long, how often it woke in the dark and why, and the charge lost.
public struct SleepReport: Equatable, Sendable {
    public let asleep: TimeInterval
    public let sleeps: Int
    public let darkWakes: Int
    /// Causes of dark wakes, most frequent first.
    public let wakeCauses: [(cause: String, count: Int)]
    /// Percent of charge lost while asleep on battery, and over how long.
    public let chargeLost: Int
    public let batteryAsleep: TimeInterval

    public static func == (a: SleepReport, b: SleepReport) -> Bool {
        a.asleep == b.asleep && a.sleeps == b.sleeps && a.darkWakes == b.darkWakes && a.chargeLost == b.chargeLost
            && a.wakeCauses.map(\.cause) == b.wakeCauses.map(\.cause)
    }

    /// Percent per hour lost while asleep on battery. A healthy MacBook loses about 1% an hour or less.
    public var lossPerHour: Double? {
        batteryAsleep >= 3600 ? Double(chargeLost) / (batteryAsleep / 3600) : nil
    }
}

public enum SleepLog {
    public static func read() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "log"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `2026-10-15 07:32:20 +0200 Sleep   Entering Sleep state due to 'Low Power Sleep':... Using Batt (Charge:84%) 2235 secs`
    public static func parse(_ text: String, since: Date? = nil) -> [SleepEvent] {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var out: [SleepEvent] = []
        for line in text.split(separator: "\n") {
            guard line.count > 27, line.first?.isNumber == true else { continue }
            let head = line.prefix(25)
            let rest = line.dropFirst(26)
            // The type column is padded to a fixed width and ends at a tab: "Wake Requests"
            // is a type of its own, not a wake.
            guard let tab = rest.firstIndex(of: "\t") else { continue }
            let kind: SleepEvent.Kind
            switch rest[..<tab].trimmingCharacters(in: .whitespaces) {
            case "Sleep": kind = .sleep
            case "DarkWake": kind = .darkWake
            case "Wake": kind = .wake
            default: continue
            }
            guard let date = fmt.date(from: String(head)) else { continue }
            if let since, date < since { continue }
            let msg = String(rest[rest.index(after: tab)...])
            var reason = ""
            if kind == .sleep, let a = msg.range(of: "due to '"), let b = msg[a.upperBound...].firstIndex(of: "'") {
                reason = String(msg[a.upperBound..<b])
            } else if let a = msg.range(of: "due to ") {
                let tail = msg[a.upperBound...]
                reason = String(tail[..<(tail.range(of: " Using ")?.lowerBound ?? tail.endIndex)]).trimmingCharacters(in: .whitespaces)
            }
            var charge: Int?
            if let c = msg.range(of: "Charge:") {
                charge = Int(msg[c.upperBound...].prefix { $0.isNumber })
            }
            let battery = msg.range(of: "Using BATT", options: .caseInsensitive) != nil
            out.append(SleepEvent(date: date, kind: kind, reason: reason, charge: charge, onBattery: battery))
        }
        return out
    }

    /// Pairs each sleep with the next full wake; dark wakes in between are counted.
    public static func report(_ events: [SleepEvent], until now: Date) -> SleepReport {
        var asleep: TimeInterval = 0, sleeps = 0, dark = 0, lost = 0
        var batteryAsleep: TimeInterval = 0
        var causes: [String: Int] = [:]
        var start: SleepEvent?
        for e in events.sorted(by: { $0.date < $1.date }) {
            switch e.kind {
            case .sleep:
                if start == nil {
                    start = e
                    sleeps += 1
                }
            case .darkWake:
                if start != nil {
                    dark += 1
                    causes[e.cause, default: 0] += 1
                }
            case .wake:
                guard let s = start else { continue }
                let span = e.date.timeIntervalSince(s.date)
                asleep += span
                if s.onBattery, e.onBattery {
                    batteryAsleep += span
                    if let a = s.charge, let b = e.charge, a > b { lost += a - b }
                }
                start = nil
            }
        }
        if let s = start { asleep += max(now.timeIntervalSince(s.date), 0) }
        let ranked = causes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { (cause: $0.key, count: $0.value) }
        return SleepReport(asleep: asleep, sleeps: sleeps, darkWakes: dark, wakeCauses: ranked,
                           chargeLost: lost, batteryAsleep: batteryAsleep)
    }
}

/// Which kind of core each process ran on. macOS does not say which core an app is on (its
/// threads hop between cores many times a second), but it does count, per process, how much
/// of its CPU time was on the performance cores.
public struct ClusterTime: Equatable, Sendable {
    /// All CPU time, in nanoseconds.
    public var total: UInt64
    /// Of that, time on the performance cores.
    public var performance: UInt64

    public init(total: UInt64, performance: UInt64) {
        self.total = total
        self.performance = performance
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return (UInt64(max(tb.numer, 1)), UInt64(max(tb.denom, 1)))
    }()

    /// nil for processes of other users, which macOS will not describe.
    public static func read(_ pid: Int32) -> ClusterTime? {
        var info = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard r == 0 else { return nil }
        // These counters are in Mach time units, not nanoseconds, on Apple silicon.
        let ns = { (t: UInt64) in t / timebase.denom * timebase.numer }
        return ClusterTime(total: ns(info.ri_user_time + info.ri_system_time),
                           performance: ns(info.ri_user_ptime + info.ri_system_ptime))
    }

    /// Percent of one core used on the efficiency and performance cores between two readings.
    public static func usage(from a: ClusterTime, to b: ClusterTime, seconds: Double) -> (efficiency: Double, performance: Double)? {
        guard seconds > 0, b.total >= a.total else { return nil }
        let total = Double(b.total - a.total)
        let perf = min(Double(b.performance >= a.performance ? b.performance - a.performance : 0), total)
        let k = 100 / (seconds * 1e9)
        return ((total - perf) * k, perf * k)
    }
}
