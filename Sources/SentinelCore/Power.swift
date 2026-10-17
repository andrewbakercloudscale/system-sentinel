import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// The battery and power supply right now: what the Mac is drawing, what is left, and how
/// healthy the battery is. Everything comes from IOKit; no admin rights needed.
public struct BatteryStatus: Equatable, Sendable {
    public var present: Bool
    public var onBattery: Bool
    public var charging: Bool
    public var fullyCharged: Bool
    /// Charge, 0 to 100.
    public var percent: Int
    /// The whole Mac's draw in watts, from the power telemetry (works plugged in too), else
    /// the battery's current times its voltage.
    public var watts: Double?
    /// macOS's own estimate, in minutes. nil while it is still calculating.
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?
    public var cycleCount: Int?
    /// The cycle count the battery is designed for (1000 on recent MacBooks).
    public var designCycles: Int?
    /// What the battery holds now against what it held new, in mAh.
    public var maxCapacity: Int?
    public var designCapacity: Int?
    /// "Normal", or macOS's warning such as "Check Battery" or "Service Recommended".
    public var condition: String?
    public var temperature: Double?
    public var adapterWatts: Int?
    public var lowPowerMode: Bool
    /// Battery voltage in volts, to turn mAh into watt-hours.
    public var voltage: Double?

    /// Energy left in the battery, in watt-hours.
    public var energyLeft: Double? {
        guard let m = maxCapacity, let v = voltage, v > 0 else { return nil }
        return Double(m) * Double(percent) / 100 * v / 1000
    }

    /// macOS's estimate, else charge left over the current draw.
    public var minutesLeft: Int? {
        guard onBattery else { return nil }
        if let m = minutesToEmpty { return m }
        guard let e = energyLeft, let w = watts, w > 0.5 else { return nil }
        return Int(e / w * 60)
    }

    /// Capacity now against new, in percent.
    public var health: Double? {
        guard let m = maxCapacity, let d = designCapacity, d > 0 else { return nil }
        return Double(m) / Double(d) * 100
    }

    public init(present: Bool = true, onBattery: Bool = false, charging: Bool = false, fullyCharged: Bool = false,
                percent: Int = 100, watts: Double? = nil, minutesToEmpty: Int? = nil, minutesToFull: Int? = nil,
                cycleCount: Int? = nil, designCycles: Int? = nil, maxCapacity: Int? = nil, designCapacity: Int? = nil,
                condition: String? = nil, temperature: Double? = nil, adapterWatts: Int? = nil, lowPowerMode: Bool = false,
                voltage: Double? = nil) {
        self.voltage = voltage
        self.present = present
        self.onBattery = onBattery
        self.charging = charging
        self.fullyCharged = fullyCharged
        self.percent = percent
        self.watts = watts
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
        self.cycleCount = cycleCount
        self.designCycles = designCycles
        self.maxCapacity = maxCapacity
        self.designCapacity = designCapacity
        self.condition = condition
        self.temperature = temperature
        self.adapterWatts = adapterWatts
        self.lowPowerMode = lowPowerMode
    }
}

public enum PowerReader {
    /// nil on a Mac without a battery (iMac, Mac mini, Studio).
    public static func read() -> BatteryStatus? {
        let source = powerSource()
        let registry = smartBattery()
        guard source != nil || registry != nil else { return nil }
        return parse(registry: registry ?? [:], source: source ?? [:],
                     lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Builds the status from the AppleSmartBattery registry entry and the IOPS power source
    /// description. Split out so it can be tested with recorded dictionaries.
    public static func parse(registry r: [String: Any], source s: [String: Any], lowPowerMode: Bool) -> BatteryStatus {
        func int(_ d: [String: Any], _ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        func bool(_ d: [String: Any], _ k: String) -> Bool? { (d[k] as? NSNumber)?.boolValue }
        // The registry's amperage is unsigned 64-bit on some Macs; read it back as signed.
        func signed(_ k: String) -> Int? {
            guard let n = r[k] as? NSNumber else { return nil }
            return Int(truncatingIfNeeded: n.int64Value)
        }

        let state = s[kIOPSPowerSourceStateKey] as? String
        let onBattery = state.map { $0 == kIOPSBatteryPowerValue } ?? !(bool(r, "ExternalConnected") ?? true)
        let charging = bool(s, kIOPSIsChargingKey) ?? bool(r, "IsCharging") ?? false

        var watts: Double?
        if let t = r["PowerTelemetryData"] as? [String: Any], let load = int(t, "SystemLoad"), load > 0 {
            watts = Double(load) / 1000
        } else if let mv = int(r, "Voltage"), let ma = signed("InstantAmperage") ?? signed("Amperage"), ma != 0 {
            watts = Double(abs(ma)) * Double(mv) / 1_000_000
        }

        // IOPS reports -1 while estimating; the registry uses 65535 for "unknown".
        func minutes(_ v: Int?) -> Int? { v.flatMap { $0 >= 0 && $0 < 65535 ? $0 : nil } }
        let toEmpty = onBattery ? minutes(int(s, kIOPSTimeToEmptyKey) ?? int(r, "AvgTimeToEmpty")) : nil
        let toFull = charging ? minutes(int(s, kIOPSTimeToFullChargeKey) ?? int(r, "AvgTimeToFull")) : nil

        let temp = int(r, "Temperature").map { Double($0) / 100 }
        let adapter = (r["AdapterDetails"] as? [String: Any]).flatMap { int($0, "Watts") }
        let condition = (s["BatteryHealth"] as? String).flatMap { $0.isEmpty ? nil : ($0 == "Good" ? "Normal" : $0) }

        return BatteryStatus(
            present: bool(r, "BatteryInstalled") ?? (s[kIOPSIsPresentKey] as? Bool) ?? true,
            onBattery: onBattery, charging: charging,
            fullyCharged: bool(r, "FullyCharged") ?? false,
            percent: int(s, kIOPSCurrentCapacityKey) ?? int(r, "CurrentCapacity") ?? 0,
            watts: watts, minutesToEmpty: toEmpty, minutesToFull: toFull,
            cycleCount: int(r, "CycleCount"), designCycles: int(s, "DesignCycleCount") ?? int(r, "DesignCycleCount9C"),
            maxCapacity: int(r, "AppleRawMaxCapacity") ?? int(r, "NominalChargeCapacity"),
            designCapacity: int(r, "DesignCapacity"),
            condition: condition, temperature: temp, adapterWatts: adapter, lowPowerMode: lowPowerMode,
            voltage: int(r, "Voltage").map { Double($0) / 1000 })
    }

    static func powerSource() -> [String: Any]? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as NSArray as [AnyObject]
        for ps in list {
            if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
               d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                return d
            }
        }
        return nil
    }

    static func smartBattery() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return props?.takeRetainedValue() as? [String: Any]
    }
}

/// A process holding the Mac awake: a power assertion that stops idle sleep or display sleep.
public struct SleepBlocker: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case system, display

        public var meaning: String {
            switch self {
            case .system: return "Keeps the Mac awake"
            case .display: return "Keeps the screen on"
            }
        }
    }

    public let pid: Int32
    public let name: String
    public let kind: Kind
    /// The assertion's own name, e.g. "caffeinate command-line tool" or a video player's reason.
    public let reason: String
    public let since: Date?
    /// caffeinate says who it works for: "on behalf of 'claude' (pid 61739)".
    public let onBehalfOf: String?
    public let onBehalfOfPID: Int32?
    /// Releases itself after this many seconds, if set.
    public let timeout: Int?
    public var id: String { "\(pid)-\(kind.rawValue)-\(reason)" }

    public init(pid: Int32, name: String, kind: Kind, reason: String, since: Date?, onBehalfOf: String? = nil,
                onBehalfOfPID: Int32? = nil, timeout: Int? = nil) {
        self.pid = pid
        self.name = name
        self.kind = kind
        self.reason = reason
        self.since = since
        self.onBehalfOf = onBehalfOf
        self.onBehalfOfPID = onBehalfOfPID
        self.timeout = timeout
    }
}

public enum SleepBlockers {
    public static func read() -> [SleepBlocker] {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let d = dict?.takeRetainedValue() as? [AnyHashable: Any] else { return [] }
        var byPID: [Int32: [[String: Any]]] = [:]
        for (k, v) in d {
            guard let pid = (k as? NSNumber)?.int32Value ?? Int32("\(k)"), let list = v as? [[String: Any]] else { continue }
            byPID[pid] = list
        }
        return parse(byPID)
    }

    /// Only assertions that stop sleep. macOS's own short-lived ones (UserIsActive from
    /// powerd, background tasks) are left out: they are not something to act on.
    public static func parse(_ byPID: [Int32: [[String: Any]]]) -> [SleepBlocker] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var out: [SleepBlocker] = []
        for (pid, list) in byPID {
            for a in list {
                let type = (a["AssertionTrueType"] as? String) ?? (a["AssertType"] as? String) ?? ""
                let kind: SleepBlocker.Kind
                switch type {
                case "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion": kind = .system
                case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": kind = .display
                default: continue
                }
                let name = (a["Process Name"] as? String) ?? "pid \(pid)"
                let details = a["Details"] as? String
                let behalf = details.flatMap(onBehalf)
                let since: Date? = {
                    if let d = a["AssertStartWhen"] as? Date { return d }
                    return (a["AssertStartWhen"] as? String).flatMap { formatter.date(from: $0) }
                }()
                out.append(SleepBlocker(pid: pid, name: name, kind: kind, reason: (a["AssertName"] as? String) ?? type,
                                        since: since, onBehalfOf: behalf?.0, onBehalfOfPID: behalf?.1,
                                        timeout: (a["TimeoutSeconds"] as? NSNumber)?.intValue))
            }
        }
        return out.sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }

    /// "caffeinate asserting on behalf of 'claude' (pid 61739)" gives ("claude", 61739).
    static func onBehalf(_ details: String) -> (String, Int32)? {
        guard let r = details.range(of: "on behalf of '") else { return nil }
        let rest = details[r.upperBound...]
        guard let q = rest.firstIndex(of: "'") else { return nil }
        let name = String(rest[..<q])
        let tail = rest[q...]
        guard let p = tail.range(of: "(pid "), let close = tail[p.upperBound...].firstIndex(of: ")"),
              let pid = Int32(tail[p.upperBound..<close]) else { return nil }
        return (name, pid)
    }
}

/// Activity Monitor's Energy Impact and idle wakeups for every process, from `top`, which
/// can read them for root processes too (it carries the entitlement an app cannot have).
public struct EnergySample: Equatable, Sendable {
    public let pid: Int32
    /// Energy Impact: a relative score, roughly CPU plus the cost of wakeups, GPU and disk.
    public let power: Double
    /// Times per second the process woke the CPU from idle.
    public let wakeups: Double
}

public enum EnergySampler {
    /// Two samples a second apart: `top`'s first sample has no interval to measure over.
    public static func sample() -> [Int32: (power: Double, idleWakeups: Int)] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        task.arguments = ["-l", "2", "-s", "1", "-stats", "pid,power,idlew"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Reads the last table in `top` output: `PID POWER IDLEW` rows. IDLEW is the running
    /// total since the process started, sometimes with a trailing "+".
    public static func parse(_ output: String) -> [Int32: (power: Double, idleWakeups: Int)] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") }) else { return [:] }
        var out: [Int32: (power: Double, idleWakeups: Int)] = [:]
        for line in lines[(header + 1)...] {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = Int32(f[0]),
                  let power = Double(f[1].replacingOccurrences(of: ",", with: ".")) else { continue }
            let w = Int(f[2].trimmingCharacters(in: CharacterSet(charactersIn: "+-*"))) ?? 0
            out[pid] = (power, w)
        }
        return out
    }
}

/// Turns successive `top` readings into wakeups per second, per process.
public final class WakeupTracker {
    private var last: [Int32: Int] = [:]
    private var lastTime: Date?

    public init() {}

    public func update(_ readings: [Int32: (power: Double, idleWakeups: Int)], at now: Date) -> [EnergySample] {
        defer {
            last = readings.mapValues(\.idleWakeups)
            lastTime = now
        }
        let span = lastTime.map { now.timeIntervalSince($0) } ?? 0
        return readings.map { pid, r in
            var rate = 0.0
            if span > 0, let before = last[pid], r.idleWakeups >= before {
                rate = Double(r.idleWakeups - before) / span
            }
            return EnergySample(pid: pid, power: r.power, wakeups: rate)
        }
    }
}

/// The Mac's power draw and battery level, minute by minute, for the last 7 days.
public final class PowerHistory {
    public struct Point: Codable, Equatable, Sendable {
        /// Minute start, seconds since 1970.
        public var t: Int
        public var watts: Double
        public var onBattery: Bool
        public var percent: Int
        /// Samples averaged into `watts`.
        public var n: Int
    }

    public private(set) var points: [Point] = []
    private let fileURL: URL?
    private let readOnly: Bool
    private let retain: TimeInterval
    private var lastSave: Date?

    public init(fileURL: URL?, retain: TimeInterval = 7 * 86_400, readOnly: Bool = false) {
        self.fileURL = fileURL
        self.retain = retain
        self.readOnly = readOnly
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let p = try? JSONDecoder().decode([Point].self, from: data) {
            points = p
        }
    }

    public func record(_ s: BatteryStatus, at now: Date) {
        guard let w = s.watts else { return }
        let minute = Int(now.timeIntervalSince1970) / 60 * 60
        if var last = points.last, last.t == minute {
            last.watts = (last.watts * Double(last.n) + w) / Double(last.n + 1)
            last.n += 1
            last.onBattery = s.onBattery
            last.percent = s.percent
            points[points.count - 1] = last
        } else {
            points.append(Point(t: minute, watts: w, onBattery: s.onBattery, percent: s.percent, n: 1))
            let cutoff = minute - Int(retain)
            if let i = points.firstIndex(where: { $0.t >= cutoff }), i > 0 { points.removeFirst(i) }
        }
        if lastSave.map({ now.timeIntervalSince($0) >= 300 }) ?? true {
            save()
            lastSave = now
        }
    }

    public func since(_ date: Date) -> [Point] {
        let t = Int(date.timeIntervalSince1970)
        return points.filter { $0.t >= t }
    }

    public func save() {
        guard !readOnly, let url = fileURL, let data = try? JSONEncoder().encode(points) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Usage on battery over a period: how long, how hard, and how fast the charge went.
public struct BatterySummary: Equatable, Sendable {
    /// Minutes with a reading, and of those, on battery.
    public let minutes: Int
    public let batteryMinutes: Int
    public let averageWatts: Double?
    public let averageBatteryWatts: Double?
    public let peakWatts: Double?
    /// Percent of charge used per hour on battery, from the level readings.
    public let drainPerHour: Double?

    public static func from(_ points: [PowerHistory.Point]) -> BatterySummary {
        let battery = points.filter(\.onBattery)
        func avg(_ p: [PowerHistory.Point]) -> Double? {
            p.isEmpty ? nil : p.reduce(0) { $0 + $1.watts } / Double(p.count)
        }
        // Drain: sum the drops between consecutive battery minutes; ignore charging gaps.
        var used = 0, span = 0
        for (a, b) in zip(battery, battery.dropFirst()) where b.t - a.t <= 300 {
            used += max(a.percent - b.percent, 0)
            span += b.t - a.t
        }
        return BatterySummary(minutes: points.count, batteryMinutes: battery.count,
                              averageWatts: avg(points), averageBatteryWatts: avg(battery),
                              peakWatts: points.map(\.watts).max(),
                              drainPerHour: span >= 600 ? Double(used) / Double(span) * 3600 : nil)
    }
}
