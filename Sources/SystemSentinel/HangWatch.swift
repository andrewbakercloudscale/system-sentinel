import AppKit
import SentinelCore

/// What the main thread is doing, for when it freezes. Set around the known slow parts;
/// read from the watchdog thread, so behind a lock.
enum Activity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var label: String?

    static var current: String? { lock.withLock { label } }
    static func set(_ s: String?) { lock.withLock { label = s } }

    /// Runs `work` labelled, for the watchdog to name if it freezes.
    static func during<T>(_ s: String, _ work: () throws -> T) rethrows -> T {
        let before = current
        set(s)
        defer { set(before) }
        return try work()
    }
}

/// Watches for hangs: System Sentinel's own window freezing, and other apps showing the
/// spinning wheel. Both end up in `Model.hangs` with what was going on at the time.
enum HangWatch {
    /// Own freezes shorter than this go unrecorded: one slow frame is not a hang.
    static let ownMinimum: TimeInterval = 0.5

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pong = CFAbsoluteTimeGetCurrent()

    static func start() {
        let t = Thread { ownLoop() }
        t.name = "HangWatch"
        t.qualityOfService = .utility
        t.start()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async {
                let hung = unresponsiveApps()
                DispatchQueue.main.async { MainActor.assumeIsolated { Model.current?.updateHangs(hung) } }
            }
        }
    }

    /// Pings the main thread every 0.1 s. When a ping goes unanswered past the minimum, it
    /// notes what the main thread was labelled as doing, and records the freeze once it ends.
    private static func ownLoop() {
        var stuck: (since: CFAbsoluteTime, doing: String?)?
        while true {
            Thread.sleep(forTimeInterval: 0.1)
            DispatchQueue.main.async { lock.withLock { pong = CFAbsoluteTimeGetCurrent() } }
            let now = CFAbsoluteTimeGetCurrent()
            let last = lock.withLock { pong }
            if now - last > ownMinimum + 0.1 {
                if stuck == nil { stuck = (last, Activity.current) }
            } else if let s = stuck {
                stuck = nil
                let seconds = last - s.since
                guard seconds >= ownMinimum else { continue }
                let start = Date(timeIntervalSinceReferenceDate: s.since)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { Model.current?.recordOwnHang(start: start, seconds: seconds, doing: s.doing) }
                }
            }
        }
    }

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias UnresponsiveFn = @convention(c) (Int32, UnsafePointer<ProcessSerialNumber>) -> Bool
    private typealias PSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    /// The window server's own "not responding" flag, the one Activity Monitor and Force
    /// Quit show. Private, so looked up at run time; if it is gone, nothing is reported.
    nonisolated(unsafe) private static let calls: (ConnectionFn, UnresponsiveFn, PSNFn)? = {
        let h = dlopen(nil, RTLD_NOW)
        guard let c = dlsym(h, "CGSMainConnectionID"), let u = dlsym(h, "CGSEventIsAppUnresponsive"),
              let p = dlsym(h, "GetProcessForPID") else { return nil }
        return (unsafeBitCast(c, to: ConnectionFn.self), unsafeBitCast(u, to: UnresponsiveFn.self), unsafeBitCast(p, to: PSNFn.self))
    }()

    /// Regular apps the window server marks as not responding, by pid.
    static func unresponsiveApps() -> [Int32: String] {
        guard let (connection, unresponsive, psnFor) = calls else { return [:] }
        let cid = connection()
        var out: [Int32: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard pid != getpid() else { continue }
            var psn = ProcessSerialNumber()
            guard psnFor(pid, &psn) == noErr, unresponsive(cid, &psn) else { continue }
            out[pid] = app.localizedName ?? "pid \(pid)"
        }
        return out
    }
}
