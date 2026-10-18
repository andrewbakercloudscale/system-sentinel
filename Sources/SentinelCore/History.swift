import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case flagged, killed, autoKilled, killFailed, rateLimited }
    public let date: Date
    public let kind: Kind
    public let pid: Int32
    public let name: String
    public let path: String
    public let cpu: Double
    public let detail: String
}

/// What was flagged and killed: kept in memory for the menu, appended to a JSON-lines file.
public final class History {
    public private(set) var entries: [HistoryEntry] = []
    private let fileURL: URL?
    private let keep: Int

    /// `seed` reads entries from a file without ever writing to it (snapshots, previews).
    public init(fileURL: URL?, keep: Int = 200, seed: URL? = nil) {
        self.fileURL = fileURL
        self.keep = keep
        if let url = fileURL ?? seed, let text = try? String(contentsOf: url, encoding: .utf8) {
            let decoder = JSONDecoder()
            entries = text.split(separator: "\n").suffix(keep).compactMap {
                try? decoder.decode(HistoryEntry.self, from: Data($0.utf8))
            }
        }
    }

    public func record(_ kind: HistoryEntry.Kind, _ s: ProcessSample, detail: String = "", at now: Date = Date()) {
        let e = HistoryEntry(date: now, kind: kind, pid: s.pid, name: s.displayName, path: s.path, cpu: s.cpu, detail: detail)
        entries.append(e)
        if entries.count > keep { entries.removeFirst(entries.count - keep) }
        guard let url = fileURL, var line = try? JSONEncoder().encode(e) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else if (try? line.write(to: url)) == nil {
            Diagnostics.report("save", "Could not write the events log \(url.lastPathComponent)")
        }
    }
}
