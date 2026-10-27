import Darwin
import Foundation

/// What a process is actually running, for when the app name says little: "Python" or
/// "node" can be a dozen unrelated scripts, servers and tools at once.
public enum ProcessDetail {
    /// One thing an interpreter runs, with its processes added up.
    public struct Job: Equatable, Sendable, Identifiable {
        /// "exitrisk serve", "http.server 8931", "inline code".
        public var what: String
        /// The folder it was started in, with the home folder as "~"; "in 16 folders" when one
        /// tool runs in many places (an MCP server per editor window). Empty when unknown.
        public var folder: String
        public var pids: [Int32]
        public var bytes: UInt64
        public var outOfRAM: UInt64
        public var id: String { what }

        public init(what: String, folder: String, pids: [Int32], bytes: UInt64, outOfRAM: UInt64) {
            self.what = what
            self.folder = folder
            self.pids = pids
            self.bytes = bytes
            self.outOfRAM = outOfRAM
        }
    }

    /// One process as read off the Mac.
    public struct Reading: Sendable {
        public var pid: Int32
        public var args: [String]
        public var folder: String
        public var bytes: UInt64
        public var outOfRAM: UInt64

        public init(pid: Int32, args: [String], folder: String, bytes: UInt64, outOfRAM: UInt64) {
            self.pid = pid
            self.args = args
            self.folder = folder
            self.bytes = bytes
            self.outOfRAM = outOfRAM
        }
    }

    /// The process's command line, from the kernel. Empty for processes of other users.
    public static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// KERN_PROCARGS2 is argc, the executable path, padding zeros, then argc strings.
    public static func parseProcArgs(_ b: [UInt8]) -> [String] {
        guard b.count > 4 else { return [] }
        let argc = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        var i = 4
        while i < b.count, b[i] != 0 { i += 1 }   // executable path
        while i < b.count, b[i] == 0 { i += 1 }   // padding
        var out: [String] = []
        while out.count < argc, i < b.count {
            let start = i
            while i < b.count, b[i] != 0 { i += 1 }
            out.append(String(decoding: b[start..<i], as: UTF8.self))
            i += 1
        }
        return out
    }

    /// The folder the process was started in.
    public static func folder(_ pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard n > 0 else { return "" }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// A short name for what the command line runs: the script or module, not the interpreter.
    public static func describe(_ args: [String]) -> String {
        guard !args.isEmpty else { return "unknown" }
        var rest = Array(args.dropFirst())
        let name = (args[0] as NSString).lastPathComponent
        while let a = rest.first {
            if a == "-m", rest.count > 1 { return join(rest[1], rest.dropFirst(2)) }
            if a == "-c" || a == "-e" {
                // Python's multiprocessing starts helpers this way: they belong to the parent.
                if rest.count > 1, rest[1].contains("multiprocessing") { return "worker (multiprocessing)" }
                return "inline code"
            }
            if a.hasPrefix("-") { rest.removeFirst(); continue }
            return join((a as NSString).lastPathComponent, rest.dropFirst())
        }
        return name
    }

    /// The script plus its first plain word or number, such as a subcommand or a port.
    private static func join(_ head: String, _ tail: ArraySlice<String>) -> String {
        guard let next = tail.first(where: { !$0.hasPrefix("-") && $0.count <= 24 && !$0.contains("/") }) else { return head }
        return head + " " + next
    }

    /// Readings grouped by what they run, largest first. Workers go with their
    /// parent's job when the parent is in the list.
    public static func jobs(_ readings: [Reading], parent: (Int32) -> Int32? = { _ in nil }, home: String = NSHomeDirectory()) -> [Job] {
        let byPid = Dictionary(readings.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        var out: [String: Job] = [:]
        var folders: [String: Set<String>] = [:]
        for r in readings {
            var owner = r
            if describe(r.args) == "worker (multiprocessing)", let p = parent(r.pid), let up = byPid[p] { owner = up }
            var folder = owner.folder
            if !home.isEmpty, folder.hasPrefix(home) { folder = "~" + folder.dropFirst(home.count) }
            let job = Job(what: describe(owner.args), folder: folder, pids: [r.pid], bytes: r.bytes, outOfRAM: r.outOfRAM)
            if !folder.isEmpty { folders[job.id, default: []].insert(folder) }
            if var j = out[job.id] {
                j.pids.append(r.pid)
                j.bytes += r.bytes
                j.outOfRAM += r.outOfRAM
                out[job.id] = j
            } else {
                out[job.id] = job
                order.append(job.id)
            }
        }
        return order.compactMap { id in
            guard var j = out[id] else { return nil }
            if let f = folders[id], f.count > 1 { j.folder = "in \(f.count) folders" }
            return j
        }.sorted { $0.bytes > $1.bytes }
    }

    /// The parent of a process.
    public static func parent(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return n > 0 ? Int32(info.pbi_ppid) : nil
    }
}
