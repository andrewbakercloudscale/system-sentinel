import Foundation

public enum KillOutcome: Equatable, Sendable {
    /// Gone after SIGTERM.
    case terminated
    /// Ignored SIGTERM, gone after SIGKILL.
    case forceKilled
    /// Already gone before anything was sent.
    case alreadyGone
    case refused(String)
    case failed(String)
}

/// Ends processes: SIGTERM first so the process can clean up, SIGKILL after a grace period.
public enum Killer {
    public static func isAlive(_ pid: Int32) -> Bool {
        // Signal 0 checks existence. EPERM means it exists but belongs to someone else.
        guard Darwin.kill(pid, 0) == 0 || errno == EPERM else { return false }
        // A killed process stays in the table as a zombie until its parent collects it, and
        // signal 0 still succeeds on a zombie. SkyComputerUseService, SIGKILLed while ChatGPT
        // (its parent) was busy, read as "still running after SIGKILL" though it was dead.
        return !isZombie(pid)
    }

    static func isZombie(_ pid: Int32) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat == SZOMB
    }

    /// SIGKILL straight away: cannot be caught or ignored, and the process gets no chance to
    /// save or clean up. Root and protected processes go through the admin prompt. pid 0 and 1
    /// and this app stay refused.
    public static func forceKill(_ s: ProcessSample) -> KillOutcome {
        guard s.pid > 1, s.pid != getpid() else { return .refused("\(s.name) cannot be killed") }
        guard isAlive(s.pid) else { return .alreadyGone }
        if s.uid != getuid() {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "do shell script \"/bin/kill -KILL \(s.pid)\" with administrator privileges"]
            task.standardError = FileHandle.nullDevice
            do { try task.run() } catch { return .failed(error.localizedDescription) }
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return .failed("admin prompt cancelled or refused") }
        } else if Darwin.kill(s.pid, SIGKILL) != 0 {
            return isAlive(s.pid) ? .failed(String(cString: strerror(errno))) : .forceKilled
        }
        return waitForExit(s.pid, timeout: 5) ? .forceKilled : .failed("still running after SIGKILL")
    }

    /// The force kill command to paste into Terminal.
    public static func forceSudoCommand(for s: ProcessSample) -> String { "sudo kill -9 \(s.pid)" }

    /// Kills a process owned by this user. Blocks for up to `grace` seconds.
    public static func kill(_ s: ProcessSample, grace: TimeInterval = 5) -> KillOutcome {
        guard Safety.canKillManually(s) else { return .refused("\(s.name) is protected") }
        guard isAlive(s.pid) else { return .alreadyGone }
        if s.uid != getuid() { return killAsAdmin(s) }
        guard Darwin.kill(s.pid, SIGTERM) == 0 else {
            return .failed(String(cString: strerror(errno)))
        }
        if waitForExit(s.pid, timeout: grace) { return .terminated }
        guard Darwin.kill(s.pid, SIGKILL) == 0 else {
            return isAlive(s.pid) ? .failed(String(cString: strerror(errno))) : .terminated
        }
        return waitForExit(s.pid, timeout: 2) ? .forceKilled : .failed("still running after SIGKILL")
    }

    /// The deliberate override for a protected process: admin prompt, after the UI has said
    /// what will happen (WindowServer logs the owner out). pid 0 and 1 and this app stay
    /// refused: there is no outcome of killing those that anyone wants.
    public static func killProtectedAsAdmin(_ s: ProcessSample) -> KillOutcome {
        guard s.pid > 1, s.pid != getpid() else { return .refused("\(s.name) cannot be killed") }
        guard isAlive(s.pid) else { return .alreadyGone }
        return killAsAdmin(s)
    }

    /// The command the owner can paste into Terminal instead.
    /// No trailing "# name" comment: interactive zsh does not treat # as a comment by
    /// default, so it reached kill as a pid ("kill: illegal process id: #").
    public static func sudoCommand(for s: ProcessSample) -> String {
        "sudo kill -TERM \(s.pid)"
    }

    /// Root and other users' processes: the standard macOS admin prompt via osascript.
    /// launchd restarts the daemons this is meant for (PerfPowerServices), so TERM is enough.
    static func killAsAdmin(_ s: ProcessSample) -> KillOutcome {
        let script = "do shell script \"/bin/kill -TERM \(s.pid)\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return .failed(error.localizedDescription) }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return .failed("admin prompt cancelled or refused") }
        return waitForExit(s.pid, timeout: 5) ? .terminated : .failed("still running after SIGTERM as admin")
    }

    static func waitForExit(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            usleep(100_000)
        }
        return !isAlive(pid)
    }
}
