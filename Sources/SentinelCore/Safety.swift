import Foundation

/// What may be done to a process. These rules are code, not settings: a setting can be
/// changed by accident, and killing any of the protected processes logs the owner out or
/// hangs the Mac.
public enum Safety {
    /// Never killed and never offered a Kill button.
    public static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Finder", "Dock",
        "SystemUIServer", "coreaudiod", "CPUSentinel", "opendirectoryd", "securityd",
        "logind", "UserEventAgent", "mds", "configd", "powerd", "syslogd", "notifyd",
    ]

    public static func isProtected(_ s: ProcessSample) -> Bool {
        s.pid <= 1 || protectedNames.contains(s.name) || s.pid == getpid()
    }

    /// Whether a Kill button is offered at all.
    public static func canKillManually(_ s: ProcessSample) -> Bool {
        !isProtected(s)
    }

    /// Whether auto-kill may act without a person. Root processes never: signalling one
    /// needs the admin password, and an unattended password prompt is not automation.
    public static func canAutoKill(_ s: ProcessSample) -> Bool {
        !isProtected(s) && !s.isRoot && s.uid == getuid()
    }
}
