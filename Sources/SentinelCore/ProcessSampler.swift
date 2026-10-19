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
        if isChromeRenderer { return "Chrome tab (renderer \(pid))" }
        // The binary has no space; the app's name does.
        return name == "SystemSentinel" ? "System Sentinel" : name
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
        task.qualityOfService = .utility
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
        return resolve(parse(String(decoding: data, as: UTF8.self)))
    }

    /// `ps` prints the full path for most processes, but a bare name ("system_profiler")
    /// for some and a bracketed one ("(system_profiler)") for a process that is exiting.
    /// Left alone, one program showed up as two or three apps in the charts and rankings.
    /// The kernel knows the real executable; a process already gone keeps its bare name.
    /// Only a path whose file name matches is taken: a program that renames itself ("claude"
    /// runs as ".../versions/2.1.301", "npm exec ..." runs as node) keeps the name it chose.
    public static func resolve(_ samples: [ProcessSample], pathOf: (Int32) -> String? = executablePath) -> [ProcessSample] {
        samples.map { s in
            guard !s.path.hasPrefix("/") else { return s }
            var path = s.path
            if path.hasPrefix("("), path.hasSuffix(")") { path = String(path.dropFirst().dropLast()) }
            if let full = pathOf(s.pid), (full as NSString).lastPathComponent == path { path = full }
            return path == s.path ? s : ProcessSample(pid: s.pid, uid: s.uid, cpu: s.cpu, path: path, rssKB: s.rssKB)
        }
    }

    /// The executable's full path from the kernel. Works for other users' processes too.
    public static func executablePath(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
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

extension ProcessSampler {
    /// When a process started, from the kernel's process table. Unlike `proc_pid_rusage`
    /// this works for root and other users' processes too. nil if the pid has gone.
    public static func startTime(of pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// The pid that started this one, so "screencapture" can be traced to the app running it.
    public static func parentPID(of pid: Int32) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }
}

public enum SamplerError: Error, Equatable {
    case psFailed(Int32)
}
