import Foundation

/// One process as seen in one sample.
public struct ProcessSample: Equatable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    /// CPU as `ps` reports it: 100 means one full core, so a busy process can exceed 100.
    public let cpu: Double
    /// Resident memory in kilobytes.
    public let rssKB: Int
    /// Full executable path where `ps` gives one, else the bare command name.
    public let path: String

    public init(pid: Int32, uid: UInt32, cpu: Double, path: String, rssKB: Int = 0) {
        self.pid = pid
        self.uid = uid
        self.cpu = cpu
        self.rssKB = rssKB
        self.path = path
    }

    /// The last path component: "Google Chrome Helper (Renderer)", "PerfPowerServices".
    public var name: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    public var isRoot: Bool { uid == 0 }

    /// A Chrome tab is a renderer helper; killing one closes that site's tabs ("Aw, Snap").
    public var isChromeRenderer: Bool {
        path.contains("Google Chrome Helper (Renderer)")
    }

    /// What the menu and notifications call this process.
    public var displayName: String {
        isChromeRenderer ? "Chrome tab (renderer \(pid))" : name
    }
}

/// Reads every process's CPU from `ps`.
///
/// WHY `ps` AND NOT libproc: `proc_pid_rusage` returns EPERM for any process owned by
/// another user, which is every root daemon, and a root daemon (PerfPowerServices at 171%
/// for 37 hours) is the case this app exists for. `ps` carries the private
/// `com.apple.system-task-ports.read` entitlement, which an ad-hoc signed app cannot have.
/// One `ps` run costs about 30 ms, so a 5 s interval is well under 1% of one core.
public enum ProcessSampler {
    public static let arguments = ["-axww", "-o", "pid=,uid=,%cpu=,rss=,comm="]

    public static func sample() throws -> [ProcessSample] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw SamplerError.psFailed(task.terminationStatus)
        }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Parses `pid uid %cpu rss comm` lines. The command is everything after the fourth field,
    /// so a path with spaces ("Google Chrome Helper (Renderer).app/...") survives whole.
    /// `ps` prints decimals with a comma in some locales (the owner's Mac prints "94,0").
    public static func parse(_ output: String) -> [ProcessSample] {
        var out: [ProcessSample] = []
        for raw in output.split(separator: "\n") {
            let line = raw.drop(while: { $0 == " " })
            var fields: [Substring] = []
            var rest = Substring(line)
            for _ in 0..<4 {
                rest = rest.drop(while: { $0 == " " })
                guard let space = rest.firstIndex(of: " ") else { break }
                fields.append(rest[..<space])
                rest = rest[space...]
            }
            let path = rest.drop(while: { $0 == " " })
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let uid = UInt32(fields[1]),
                  let cpu = Double(fields[2].replacingOccurrences(of: ",", with: ".")),
                  let rss = Int(fields[3]),
                  !path.isEmpty
            else { continue }
            out.append(ProcessSample(pid: pid, uid: uid, cpu: cpu, path: String(path), rssKB: rss))
        }
        return out
    }
}

public enum SamplerError: Error, Equatable {
    case psFailed(Int32)
}
