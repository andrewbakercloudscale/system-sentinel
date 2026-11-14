import AppKit
import ServiceManagement
import SentinelCore

/// Starting at login: the app's own login item.
enum LoginItem {
    enum State { case on, off, needsApproval }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    static var enabled: Bool { state == .on }

    /// Opened by the watchdog after a crash: stay in the menu bar, like a launch at login.
    static let launchedInBackground = CommandLine.arguments.contains("--background")

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// The launch agent 0.8.43 used instead. launchd refuses to start an agent once the app is
    /// replaced by an update (a self-signed app's agent is pinned to one exact build), so it
    /// left people with nothing at login. Its plist stays in the app so it can be removed here.
    private static var oldAgent: SMAppService { .agent(plistName: "consulting.cloudscale.systemsentinel.agent.plist") }

    /// At launch. Moves 0.8.43's agent back to the login item, and starts a new install at
    /// login unless turned off, in the welcome or Settings; asked once, so off stays off.
    static func settle(newInstall: Bool) {
        let agent = oldAgent
        if [.enabled, .requiresApproval].contains(agent.status) {
            try? agent.unregister()
            try? set(true)
        }
        let key = "loginDefaultApplied"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if newInstall, state == .off { try? set(true) }
    }
}

/// Opens System Sentinel again if it crashes. A second process, the app's own binary run
/// with `--watchdog <pid>`, waits for the app to end; a quit, logout, restart or update
/// removes the crash marker first, so only a crash (or a force quit) brings it back. At
/// most 3 times in 10 minutes, so an app that crashes as it starts is not opened forever.
enum Watchdog {
    static func start() {
        guard Model.snapshotDir == nil, Bundle.main.bundlePath.hasSuffix(".app"), let exe = Bundle.main.executablePath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--watchdog", String(ProcessInfo.processInfo.processIdentifier)]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// In the watchdog process, before anything else: waits, then exits. Never returns.
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--watchdog"), i + 1 < args.count, let pid = Int32(args[i + 1]) else { return }
        setpriority(PRIO_PROCESS, 0, 10)
        let app = Bundle.main.bundleURL
        let marker = Model.supportDir.appendingPathComponent("running")
        let log = Model.supportDir.appendingPathComponent("watchdog-restarts")
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        func ended() -> Never {
            // A moment for a SIGTERM or quit handler to remove the marker.
            Thread.sleep(forTimeInterval: 1)
            let now = Date()
            let past = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
            guard FileManager.default.fileExists(atPath: marker.path), RestartPolicy.allows(past: past, now: now) else { exit(0) }
            let keep = RestartPolicy.recent(past + [now], now: now)
            try? keep.map { String($0.timeIntervalSince1970) }.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", app.path, "--args", "--background"]
            try? open.run()
            open.waitUntilExit()
            exit(0)
        }
        source.setEventHandler { ended() }
        source.resume()
        // Gone before the source was watching.
        if kill(pid, 0) != 0 && errno == ESRCH { ended() }
        dispatchMain()
    }
}

/// One copy at a time: whichever holds the lock runs and any other leaves. One opened by a
/// person asks the running copy for its window.
enum SingleInstance {
    private static var fd: Int32 = -1
    static let show = Notification.Name("consulting.cloudscale.systemsentinel.show")

    static func claim() {
        guard Model.snapshotDir == nil else { return }
        try? FileManager.default.createDirectory(at: Model.supportDir, withIntermediateDirectories: true)
        // Close-on-exec: a command the app runs (the watchdog among them) must not hold the lock.
        fd = open(Model.supportDir.appendingPathComponent("running.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) != 0 else { return }
        if !LoginItem.launchedInBackground {
            DistributedNotificationCenter.default().postNotificationName(show, object: nil, userInfo: nil, deliverImmediately: true)
        }
        exit(0)
    }

    static func listen() {
        DistributedNotificationCenter.default().addObserver(forName: show, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if let m = Model.current { PopOut.show(m) } }
        }
    }
}
