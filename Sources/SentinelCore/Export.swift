import Foundation

/// The app's readings as CSV and JSON files: history, the events log, the processes running
/// now, and a full report with all of it. Times are ISO 8601 in UTC and numbers use a dot,
/// whatever the Mac's region, so any spreadsheet or script reads them the same way.
/// CPU is in percent of the whole Mac (100 is every core busy), as the app shows it.
public enum DataExport {
    public enum Format: String, CaseIterable, Sendable { case csv, json }

    // MARK: History

    public struct CPUPoint: Codable, Equatable, Sendable {
        public var time: Date
        /// 3600 for the hourly readings that go back days, 60 for the last few hours.
        public var bucketSeconds: Int
        public var percentOfMac: Double
    }

    public struct MemoryPoint: Codable, Equatable, Sendable {
        public var time: Date
        public var usedBytes: UInt64
        public var compressedBytes: UInt64
        public var swapBytes: UInt64
        /// "normal", "under pressure" or "critical": the worst seen in the minute.
        public var pressure: String
        public var swapInBytesPerSecond: Double
        public var swapOutBytesPerSecond: Double
    }

    public struct PowerPoint: Codable, Equatable, Sendable {
        public var time: Date
        public var watts: Double
        public var onBattery: Bool
        public var batteryPercent: Int
        /// Plugged in but the battery still going down. nil before this was recorded.
        public var drainingOnPower: Bool?
    }

    public struct StoragePoint: Codable, Equatable, Sendable {
        public var time: Date
        public var usedBytes: UInt64
        public var freeBytes: UInt64
        public var purgeableBytes: UInt64
    }

    public struct NetworkPoint: Codable, Equatable, Sendable {
        public var time: Date
        public var downloadBytesPerSecond: Double
        public var uploadBytesPerSecond: Double
    }

    public struct HistoryData: Codable, Equatable, Sendable {
        public var cores: Int
        public var cpu: [CPUPoint]
        public var memory: [MemoryPoint]
        public var power: [PowerPoint]
        public var storage: [StoragePoint]
        public var network: [NetworkPoint]

        public init(cores: Int, cpu: [CPUPoint] = [], memory: [MemoryPoint] = [], power: [PowerPoint] = [],
                    storage: [StoragePoint] = [], network: [NetworkPoint] = []) {
            self.cores = cores; self.cpu = cpu; self.memory = memory; self.power = power
            self.storage = storage; self.network = network
        }
    }

    /// Total CPU per bucket from a usage store, skipping buckets nothing was sampled in.
    public static func cpuPoints(_ usage: DailyUsage, cores: Int) -> [CPUPoint] {
        let c = Double(max(cores, 1))
        return usage.coverage.keys.sorted().compactMap { b in
            guard let secs = usage.coverage[b], secs > 0 else { return nil }
            let coreSeconds = usage.entries.values.reduce(0) { $0 + ($1.hours[b] ?? 0) }
            return CPUPoint(time: Date(timeIntervalSince1970: Double(b)), bucketSeconds: usage.bucket,
                            percentOfMac: coreSeconds / secs * 100 / c)
        }
    }

    public static func pressureName(_ raw: Int) -> String {
        switch MemoryStatus.Pressure(rawValue: raw) ?? .normal {
        case .normal: return "normal"
        case .warning: return "under pressure"
        case .critical: return "critical"
        }
    }

    public static func memory(_ points: [MemoryHistory.Point]) -> [MemoryPoint] {
        points.map { MemoryPoint(time: $0.date, usedBytes: $0.used, compressedBytes: $0.compressed, swapBytes: $0.swap,
                                 pressure: pressureName($0.pressure), swapInBytesPerSecond: $0.swapIn, swapOutBytesPerSecond: $0.swapOut) }
    }

    public static func power(_ points: [PowerHistory.Point]) -> [PowerPoint] {
        points.map { PowerPoint(time: Date(timeIntervalSince1970: Double($0.t)), watts: $0.watts, onBattery: $0.onBattery,
                                batteryPercent: $0.percent, drainingOnPower: $0.draining) }
    }

    public static func storage(_ points: [StorageHistory.Point]) -> [StoragePoint] {
        points.map { StoragePoint(time: $0.date, usedBytes: $0.used, freeBytes: $0.free, purgeableBytes: $0.purgeable) }
    }

    public static func network(_ points: [Throughput.Point]) -> [NetworkPoint] {
        points.map { NetworkPoint(time: $0.at, downloadBytesPerSecond: $0.down, uploadBytesPerSecond: $0.up) }
    }

    /// One reading per row, all series in one sheet: time, metric, value, unit. Sorted by
    /// time, so a pivot table or a filter on `metric` gives any chart.
    public static func historyCSV(_ h: HistoryData) -> String {
        var rows: [(Date, [String])] = []
        func add(_ t: Date, _ metric: String, _ v: Double, _ unit: String) { rows.append((t, [time(t), metric, num(v), unit])) }
        for p in h.cpu { add(p.time, p.bucketSeconds >= 3600 ? "cpu_hourly" : "cpu_minute", p.percentOfMac, "% of Mac") }
        for p in h.memory {
            add(p.time, "memory_used", Double(p.usedBytes), "bytes")
            add(p.time, "memory_compressed", Double(p.compressedBytes), "bytes")
            add(p.time, "swap_used", Double(p.swapBytes), "bytes")
            add(p.time, "memory_pressure", Double(MemoryStatus.Pressure.allNames.firstIndex(of: p.pressure) ?? 0), "0 normal, 1 under pressure, 2 critical")
            add(p.time, "swap_in", p.swapInBytesPerSecond, "bytes/s")
            add(p.time, "swap_out", p.swapOutBytesPerSecond, "bytes/s")
        }
        for p in h.power {
            add(p.time, "power", p.watts, "W")
            add(p.time, "on_battery", p.onBattery ? 1 : 0, "1 yes, 0 no")
            add(p.time, "battery", Double(p.batteryPercent), "%")
            if let d = p.drainingOnPower { add(p.time, "draining_on_power", d ? 1 : 0, "1 yes, 0 no") }
        }
        for p in h.storage {
            add(p.time, "disk_used", Double(p.usedBytes), "bytes")
            add(p.time, "disk_free", Double(p.freeBytes), "bytes")
            add(p.time, "disk_purgeable", Double(p.purgeableBytes), "bytes")
        }
        for p in h.network {
            add(p.time, "network_download", p.downloadBytesPerSecond, "bytes/s")
            add(p.time, "network_upload", p.uploadBytesPerSecond, "bytes/s")
        }
        let sorted = rows.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
        return csv(header: ["time", "metric", "value", "unit"], rows: sorted)
    }

    // MARK: Events

    public struct Event: Codable, Equatable, Sendable {
        public var time: Date
        /// flagged, killed, autoKilled, killFailed or rateLimited.
        public var kind: String
        public var pid: Int32
        public var name: String
        public var path: String
        public var cpuPercentOfMac: Double
        public var detail: String
    }

    public static func events(_ entries: [HistoryEntry], cores: Int) -> [Event] {
        let c = Double(max(cores, 1))
        return entries.map { Event(time: $0.date, kind: $0.kind.rawValue, pid: $0.pid, name: $0.name, path: $0.path,
                                   cpuPercentOfMac: $0.cpu / c, detail: $0.detail) }
    }

    public static func eventsCSV(_ events: [Event]) -> String {
        csv(header: ["time", "kind", "pid", "name", "path", "cpu_percent_of_mac", "detail"],
            rows: events.map { [time($0.time), $0.kind, String($0.pid), $0.name, $0.path, num($0.cpuPercentOfMac), $0.detail] })
    }

    // MARK: Processes

    public struct Process: Codable, Equatable, Sendable {
        public var pid: Int32
        public var name: String
        public var path: String
        /// "root" or "you".
        public var user: String
        public var cpuPercentOfMac: Double
        /// The last 15 minutes, nil where there is not that much history.
        public var cpu15MinPercentOfMac: Double?
        public var memoryBytes: UInt64
        /// Share of the GPU, where measured.
        public var gpuPercent: Double?

        public init(pid: Int32, name: String, path: String, user: String, cpuPercentOfMac: Double,
                    cpu15MinPercentOfMac: Double? = nil, memoryBytes: UInt64, gpuPercent: Double? = nil) {
            self.pid = pid; self.name = name; self.path = path; self.user = user
            self.cpuPercentOfMac = cpuPercentOfMac; self.cpu15MinPercentOfMac = cpu15MinPercentOfMac
            self.memoryBytes = memoryBytes; self.gpuPercent = gpuPercent
        }
    }

    /// `ps` readings on the whole-Mac scale, busiest first. `average` gives a process's last
    /// 15 minutes on the `ps` scale (100 is one core).
    public static func processes(_ samples: [ProcessSample], cores: Int, average: (ProcessSample) -> Double? = { _ in nil },
                                 gpu: (Int32) -> Double? = { _ in nil }) -> [Process] {
        let c = Double(max(cores, 1))
        return samples.sorted { ($0.cpu, $1.pid) > ($1.cpu, $0.pid) }.map { s in
            Process(pid: s.pid, name: s.displayName, path: s.path, user: s.isRoot ? "root" : "you",
                    cpuPercentOfMac: s.cpu / c, cpu15MinPercentOfMac: average(s).map { $0 / c },
                    memoryBytes: UInt64(max(s.rssKB, 0)) * 1024, gpuPercent: gpu(s.pid))
        }
    }

    public static func processesCSV(_ list: [Process]) -> String {
        csv(header: ["pid", "name", "path", "user", "cpu_percent_of_mac", "cpu_15min_percent_of_mac", "memory_bytes", "gpu_percent"],
            rows: list.map { [String($0.pid), $0.name, $0.path, $0.user, num($0.cpuPercentOfMac),
                              $0.cpu15MinPercentOfMac.map(num) ?? "", String($0.memoryBytes), $0.gpuPercent.map(num) ?? ""] })
    }

    // MARK: Full report

    public struct Report: Codable, Equatable, Sendable {
        public struct Section: Codable, Equatable, Sendable {
            public var heading: String
            public var lines: [String]
        }
        public var generated: Date
        public var app: String
        public var macOS: String
        public var mac: String
        public var cores: Int
        public var memoryBytes: UInt64
        /// The same page as the Markdown and PDF report.
        public var summary: [Section]
        public var history: HistoryData
        public var events: [Event]
        public var processes: [Process]

        public init(generated: Date, app: String, macOS: String, mac: String, cores: Int, memoryBytes: UInt64,
                    summary: ReportDocument?, history: HistoryData, events: [Event], processes: [Process]) {
            self.generated = generated; self.app = app; self.macOS = macOS; self.mac = mac
            self.cores = cores; self.memoryBytes = memoryBytes
            self.summary = summary?.sections.map { Section(heading: $0.heading, lines: $0.lines) } ?? []
            self.history = history; self.events = events; self.processes = processes
        }
    }

    // MARK: Encoding

    public static func json<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(type, from: data)
    }

    /// RFC 4180: comma separated, CRLF line ends, a field in quotes when it holds a comma,
    /// quote or line break, with quotes inside doubled.
    public static func csv(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(field).joined(separator: ",") + "\r\n" }.joined()
    }

    static func field(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// "2025-06-01T09:30:00Z".
    public static func time(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// Up to 3 decimals with a dot, trailing zeros dropped: "12.5", "3", "0.125".
    public static func num(_ v: Double) -> String {
        guard v.isFinite else { return "" }
        var s = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    /// "System Sentinel history 2025-06-01.csv".
    public static func filename(_ what: String, _ format: Format, at now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "System Sentinel \(what) \(f.string(from: now)).\(format.rawValue)"
    }
}

extension MemoryStatus.Pressure {
    /// The export names, in raw-value order.
    static let allNames = ["normal", "under pressure", "critical"]
}
