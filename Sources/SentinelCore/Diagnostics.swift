import Foundation
import os

// MARK: The error log

/// Failures nobody would otherwise see: a history file that would not save, a scan that
/// timed out, a cleanup that half worked. One JSON line each, in a small file that rotates
/// so it never grows past `maxBytes` (plus one older file).
public final class ErrorLog: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var date: Date
        /// Where it happened: "save", "storage", "checkup", "update", "action"…
        public var area: String
        public var message: String
        public init(date: Date, area: String, message: String) {
            self.date = date; self.area = area; self.message = message
        }
    }

    /// The same failure, folded together.
    public struct Summary: Equatable, Sendable, Identifiable {
        public var area: String
        public var message: String
        public var count: Int
        public var first: Date
        public var last: Date
        public var id: String { area + "|" + message }
    }

    public let fileURL: URL?
    public let maxBytes: Int
    private let lock = NSLock()
    private var entries: [Entry] = []
    /// Kept in memory for the Diagnostics card; the file keeps more.
    private let keep = 500

    public init(fileURL: URL?, maxBytes: Int = 256 * 1024) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        guard let url = fileURL else { return }
        let older = (try? String(contentsOf: ErrorLog.rotated(url), encoding: .utf8)) ?? ""
        let now = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let decoder = ErrorLog.decoder
        entries = (older + now).split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
        if entries.count > keep { entries.removeFirst(entries.count - keep) }
    }

    static func rotated(_ url: URL) -> URL { url.appendingPathExtension("1") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func record(_ area: String, _ message: String, at now: Date = Date()) {
        let e = Entry(date: now, area: area, message: message)
        lock.lock()
        defer { lock.unlock() }
        entries.append(e)
        if entries.count > keep { entries.removeFirst(entries.count - keep) }
        guard let url = fileURL, var line = try? ErrorLog.encoder.encode(e) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Rotate before the file passes the limit: the current one becomes the older one.
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size + line.count > maxBytes {
            try? fm.removeItem(at: ErrorLog.rotated(url))
            try? fm.moveItem(at: url, to: ErrorLog.rotated(url))
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    public var all: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Failures since `since`, the same ones folded together, most recent first.
    public func summary(since: Date = .distantPast) -> [Summary] {
        var out: [String: Summary] = [:]
        for e in all where e.date >= since {
            let id = e.area + "|" + e.message
            if var s = out[id] {
                s.count += 1
                s.first = min(s.first, e.date)
                s.last = max(s.last, e.date)
                out[id] = s
            } else {
                out[id] = Summary(area: e.area, message: e.message, count: 1, first: e.date, last: e.date)
            }
        }
        return out.values.sorted { $0.last > $1.last }
    }
}

/// Where SentinelCore reports failures. The app points `log` at its error log; tests can too.
public enum Diagnostics {
    nonisolated(unsafe) public static var log: ErrorLog?

    public static func report(_ area: String, _ message: String) {
        // Also to the unified log: Console.app, filter on the subsystem.
        Logger(subsystem: "consulting.cloudscale.systemsentinel", category: area).error("\(message, privacy: .public)")
        log?.record(area, message)
    }

    /// Writes a file and says so when it cannot, instead of failing silently.
    @discardableResult
    public static func write(_ data: Data, to url: URL, what: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            report("save", "Could not save \(what): \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: Background jobs

/// The jobs that run on their own, and when each last finished. One that has not finished in
/// three of its intervals has stalled (a hung tool, a timer that stopped).
public struct TaskHealth: Sendable {
    public enum Job: String, CaseIterable, Sendable {
        case sampling, energy, storageScan, folderTree, checkup, updateCheck, networkDoctor

        /// How often it is meant to run.
        public var interval: TimeInterval {
            switch self {
            case .sampling: return 5
            case .energy: return 15
            case .storageScan, .checkup, .updateCheck: return 6 * 3600
            case .folderTree: return 86_400
            case .networkDoctor: return 600
            }
        }

        public var title: String {
            switch self {
            case .sampling: return "Process sampling"
            case .energy: return "Energy readings"
            case .storageScan: return "Storage scan"
            case .folderTree: return "Folder sizes"
            case .checkup: return "Checkup"
            case .updateCheck: return "Update check"
            case .networkDoctor: return "DNS checks"
            }
        }

        /// Slack for jobs that take a while themselves or start late after launch.
        var grace: TimeInterval {
            switch self {
            case .sampling, .energy: return 60
            case .storageScan, .checkup, .updateCheck: return 1800
            case .folderTree: return 3 * 3600
            case .networkDoctor: return 300
            }
        }
    }

    public private(set) var last: [Job: Date] = [:]
    public let started: Date

    public init(started: Date = Date()) { self.started = started }

    public mutating func ran(_ job: Job, at now: Date = Date()) { last[job] = now }

    /// Jobs that should have finished by now and have not. A job never run counts from launch.
    /// `skip` leaves out jobs that are off (the update check, when turned off).
    public func stale(at now: Date = Date(), skip: Set<Job> = []) -> [Job] {
        Job.allCases.filter { job in
            guard !skip.contains(job) else { return false }
            let since = last[job] ?? started
            return now.timeIntervalSince(since) > job.interval * 3 + job.grace
        }
    }
}

// MARK: Crashes

/// A marker file present while the app runs. Finding it at launch means the last run did not
/// end through a normal quit. Only a crash report written since then makes it a crash: a
/// power cut or a force quit leaves the marker too, and those are not the app's fault.
public struct CrashMarker {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// Call at launch. Returns when the last run started, if it did not quit normally.
    public func launch(at now: Date = Date()) -> Date? {
        let fm = FileManager.default
        var unclean: Date?
        if let text = try? String(contentsOf: fileURL, encoding: .utf8), let t = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            unclean = Date(timeIntervalSince1970: t)
        } else if fm.fileExists(atPath: fileURL.path) {
            unclean = (try? fm.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date ?? .distantPast
        }
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(now.timeIntervalSince1970).write(to: fileURL, atomically: true, encoding: .utf8)
        return unclean
    }

    /// Call on a normal quit.
    public func cleanExit() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The newest crash report for `process` written after `after`, from macOS's folder.
    public static func report(for process: String, after: Date, in dir: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(process + "-") && ["ips", "crash"].contains($0.pathExtension) }
            .compactMap { url -> (URL, Date)? in
                guard let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d >= after else { return nil }
                return (url, d)
            }
            .max { $0.1 < $1.1 }?.0
    }
}
