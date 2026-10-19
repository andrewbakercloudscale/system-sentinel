import Foundation
import SentinelCore

/// Lower priority: a busy process keeps running, on the efficiency cores with its disk access
/// last in line, so the apps you are using stay quick. Undone the same way, at any time.
extension Model {
    func isSlowed(_ s: ProcessSample) -> Bool { slowed.contains(s.pid) }

    /// Only for processes of this user: macOS lets an app change those without a password.
    func canSlow(_ s: ProcessSample) -> Bool { s.uid == getuid() && s.pid != getpid() && s.pid > 1 }

    func slowDown(_ s: ProcessSample, always: Bool = false) {
        if always {
            slowRules.insert(s.name)
            UserDefaults.standard.set(Array(slowRules), forKey: "slowRules")
        }
        if setBackground(s.pid, true) {
            slowed.insert(s.pid)
            lastAction = "\(s.displayName) now runs at background priority" + (always ? ", and always will" : "")
        } else {
            showToast(Toast(ok: false, title: "Could not lower \(s.displayName)", detail: "macOS refused: it may have just quit, or belong to another user."))
        }
    }

    func restore(_ s: ProcessSample) {
        if slowRules.remove(s.name) != nil { UserDefaults.standard.set(Array(slowRules), forKey: "slowRules") }
        // Every running copy of a ruled name goes back too, not just this row.
        let pids = sentinel.latest.filter { $0.name == s.name && slowed.contains($0.pid) }.map(\.pid) + [s.pid]
        for pid in Set(pids) where setBackground(pid, false) { slowed.remove(pid) }
        lastAction = "\(s.displayName) is back to normal priority"
    }

    func removeSlowRule(_ name: String) {
        slowRules.remove(name)
        UserDefaults.standard.set(Array(slowRules), forKey: "slowRules")
        for s in sentinel.latest where s.name == name && slowed.contains(s.pid) {
            if setBackground(s.pid, false) { slowed.remove(s.pid) }
        }
    }

    /// New processes with an "always" name start low as soon as they are seen. Builds start a
    /// fresh compiler for each file, so a rule is what keeps a build in the background.
    func applySlowRules() {
        guard !slowRules.isEmpty else { return }
        for s in sentinel.latest where slowRules.contains(s.name) && !slowed.contains(s.pid) && canSlow(s) {
            if setBackground(s.pid, true) { slowed.insert(s.pid) }
        }
    }

    private func setBackground(_ pid: Int32, _ on: Bool) -> Bool {
        setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0) == 0
    }
}
