import AppKit
import ServiceManagement

/// Starting at login, through the launch agent inside the app (Resources/LaunchAgent.plist).
/// Unlike a plain login item, launchd also starts the app again if it crashes; a quit exits 0
/// and stays quit.
enum LoginItem {
    static let label = "consulting.cloudscale.systemsentinel.agent"
    static var agent: SMAppService { .agent(plistName: label + ".plist") }

    enum State { case on, off, needsApproval, plainLoginItem }

    static var state: State {
        switch agent.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return SMAppService.mainApp.status == .enabled ? .plainLoginItem : .off
        }
    }

    static var enabled: Bool { [.on, .plainLoginItem].contains(state) }

    /// Started by the agent (at login or after a crash), not by a person.
    static let launchedByAgent = CommandLine.arguments.contains("--background")

    static func set(_ on: Bool) throws {
        if on {
            try agent.register()
            // Only once the agent is in: two would start two copies at login.
            try? SMAppService.mainApp.unregister()
        } else {
            try? agent.unregister()
            try? SMAppService.mainApp.unregister()
        }
    }

    /// At launch. Before 0.8.43 the app was a plain login item, which nothing restarts after a
    /// crash: move it to the agent. A new install starts at login unless turned off, in the
    /// welcome or Settings; asked once, so turning it off stays off.
    static func settle(newInstall: Bool) {
        if state == .plainLoginItem { try? set(true) }
        let key = "loginDefaultApplied"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if newInstall, state == .off { try? set(true) }
    }
}

/// One copy at a time. Registering the agent starts a copy at once and `open` after an update
/// can race the agent, so whichever copy holds the lock runs and any other leaves (exit 0, so
/// launchd does not start it again). One opened by a person asks the running copy for its window.
enum SingleInstance {
    private static var fd: Int32 = -1
    static let show = Notification.Name("consulting.cloudscale.systemsentinel.show")

    static func claim() {
        guard Model.snapshotDir == nil else { return }
        try? FileManager.default.createDirectory(at: Model.supportDir, withIntermediateDirectories: true)
        // Close-on-exec: a command the app runs must not keep the lock after the app is gone.
        fd = open(Model.supportDir.appendingPathComponent("running.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) != 0 else { return }
        if !LoginItem.launchedByAgent {
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
