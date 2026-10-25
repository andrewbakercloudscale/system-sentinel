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
    /// `ps` state letters: "R" running, "S" sleeping, "U" stuck waiting (disk or paging).
    /// Empty where the sample did not read it.
    public let state: String

    public init(pid: Int32, uid: UInt32, cpu: Double, path: String, rssKB: Int = 0, state: String = "") {
        self.pid = pid
        self.state = state
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
    /// The same with the parent pid, so the commands this app runs can be told apart.
    public static let argumentsWithParent = ["-axww", "-o", "pid=,uid=,%cpu=,rss=,ppid=,comm="]
    /// The same with the state, so the Processes tab can say what a process is waiting on.
    public static let argumentsWithState = ["-axww", "-o", "pid=,uid=,%cpu=,rss=,ppid=,stat=,comm="]

    public static func sample() throws -> [ProcessSample] {
        try sample(foldingInto: nil)
    }

    /// With `me` set, every process `me` started (nettop, ps, ping and the rest, and what
    /// they start) is counted as part of `me` and left out of the list. Before, the app's
    /// own nettop showed up as a heavy user in Trends and was flagged and killed in Events.
    public static func sample(foldingInto me: Int32?) throws -> [ProcessSample] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.qualityOfService = .utility
        task.arguments = me == nil ? arguments : argumentsWithState
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw SamplerError.psFailed(task.terminationStatus)
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let me else { return resolve(parse(text)) }
        return resolve(fold(parseWithState(text), into: me))
    }

    /// Adds the CPU and memory of every descendant of `me` to `me`'s own row and drops them.
    public static func fold(_ rows: [(sample: ProcessSample, ppid: Int32)], into me: Int32) -> [ProcessSample] {
        var parent: [Int32: Int32] = [:]
        for r in rows { parent[r.sample.pid] = r.ppid }
        func isMine(_ pid: Int32) -> Bool {
            var p = parent[pid]
            var hops = 0
            while let q = p, q > 1, hops < 32 {
                if q == me { return true }
                p = parent[q]; hops += 1
            }
            return false
        }
        var cpu = 0.0, rss = 0
        var out: [ProcessSample] = []
        for r in rows {
            if isMine(r.sample.pid) { cpu += r.sample.cpu; rss += r.sample.rssKB } else { out.append(r.sample) }
        }
        guard cpu > 0 || rss > 0, let i = out.firstIndex(where: { $0.pid == me }) else { return out }
        let s = out[i]
        out[i] = ProcessSample(pid: s.pid, uid: s.uid, cpu: s.cpu + cpu, path: s.path, rssKB: s.rssKB + rss, state: s.state)
        return out
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
            return path == s.path ? s : ProcessSample(pid: s.pid, uid: s.uid, cpu: s.cpu, path: path, rssKB: s.rssKB, state: s.state)
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
        rows(output, fields: 4).map(\.sample)
    }

    /// `pid uid %cpu rss ppid comm` lines.
    public static func parseWithParents(_ output: String) -> [(sample: ProcessSample, ppid: Int32)] {
        rows(output, fields: 5)
    }

    /// `pid uid %cpu rss ppid stat comm` lines.
    public static func parseWithState(_ output: String) -> [(sample: ProcessSample, ppid: Int32)] {
        rows(output, fields: 6)
    }

    private static func rows(_ output: String, fields count: Int) -> [(sample: ProcessSample, ppid: Int32)] {
        var out: [(sample: ProcessSample, ppid: Int32)] = []
        for raw in output.split(separator: "\n") {
            let line = raw.drop(while: { $0 == " " })
            var fields: [Substring] = []
            var rest = Substring(line)
            for _ in 0..<count {
                rest = rest.drop(while: { $0 == " " })
                guard let space = rest.firstIndex(of: " ") else { break }
                fields.append(rest[..<space])
                rest = rest[space...]
            }
            let path = rest.drop(while: { $0 == " " })
            guard fields.count == count,
                  let pid = Int32(fields[0]),
                  let uid = UInt32(fields[1]),
                  let cpu = Double(fields[2].replacingOccurrences(of: ",", with: ".")),
                  let rss = Int(fields[3]),
                  !path.isEmpty
            else { continue }
            let ppid = count > 4 ? Int32(fields[4]) ?? 0 : 0
            let state = count > 5 ? String(fields[5]) : ""
            out.append((ProcessSample(pid: pid, uid: uid, cpu: cpu, path: String(path), rssKB: rss, state: state), ppid))
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
