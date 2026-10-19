import AppKit
import SentinelCore
import SwiftUI

/// Every action asks first, in the same card: what it is, what happens, how to undo it.
/// The buttons call these; the work itself stays in Model.
extension Model {
    private static let red = Theme.heat(100)

    /// The same figures the insight quotes: the apps' whole footprint, split into RAM and what is
    /// compressed or in swap. RSS alone counts only the RAM part and undersells a quit.
    func memoryText(_ pids: [Int32]) -> String? {
        let wanted = Set(pids)
        let apps = memoryApps.filter { !wanted.isDisjoint(with: $0.pids) }
        let bytes = apps.map(\.bytes).reduce(0, +)
        guard bytes > 0 else {
            let kb = pids.compactMap { sample(pid: $0)?.rssKB }.reduce(0, +)
            return kb > 0 ? "Frees about \(Fmt.memory(kb)) of memory." : nil
        }
        let away = apps.map(\.outOfRAM).reduce(0, +)
        guard away > 0 else { return "Frees about \(ReportDocument.bytes(bytes)) of memory." }
        let inRAM = bytes > away ? bytes - away : 0
        return "Frees about \(ReportDocument.bytes(bytes)) of memory: \(ReportDocument.bytes(inRAM)) of RAM and "
            + "\(ReportDocument.bytes(away)) that is compressed or in swap."
    }

    // MARK: Processes

    func confirmKill(_ s: ProcessSample) {
        var points = ["Asks it to stop the normal way, so it can save and clean up.",
                      "If it is still running after 5 seconds, it is stopped by force."]
        if s.isRoot { points.append("It runs as root, so macOS asks for your password.") }
        if let m = memoryText([s.pid]) { points.append(m) }
        Confirm.ask(ConfirmRequest(symbol: "xmark.octagon.fill", tint: Self.red, title: "Kill \(s.displayName)?",
                                   message: "pid \(s.pid)\(uptime(s).map { ", running \($0)" } ?? "").",
                                   points: points,
                                   undo: "Open it again to undo. Anything it had not saved is lost.",
                                   confirm: .init(title: "Kill", destructive: true) { self.kill(s) }))
    }

    func confirmForceKill(_ s: ProcessSample) {
        let protected = !Safety.canKillManually(s)
        var points = ["Stops it at once (kill -9). It cannot refuse, and gets no chance to save or clean up."]
        if protected { points.append(SudoButton.consequence(of: s.name)) }
        if s.uid != getuid() { points.append("It runs as \(s.isRoot ? "root" : "another user"), so macOS asks for your password.") }
        var others: [ConfirmRequest.Choice] = []
        if s.uid != getuid() { others.append(.init(title: "Open sudo shell") { self.openSudoShell(s, force: true) }) }
        Confirm.ask(ConfirmRequest(symbol: "bolt.fill", tint: Self.red, title: "Force kill \(s.displayName)?",
                                   message: "pid \(s.pid). Use Kill first: it lets the process save.",
                                   points: points, undo: "Cannot be undone. Open the app again to start it fresh.",
                                   command: s.uid != getuid() ? Killer.forceSudoCommand(for: s) : nil,
                                   confirm: .init(title: "Force kill", destructive: true) { self.forceKill(s) }, others: others))
    }

    func confirmSudoKill(_ s: ProcessSample) {
        Confirm.ask(ConfirmRequest(symbol: "lock.fill", tint: Self.red, title: "Kill \(s.name) as admin?",
                                   message: "pid \(s.pid). A protected macOS process.",
                                   points: [SudoButton.consequence(of: s.name), "macOS asks for your password."],
                                   undo: "macOS restarts most of its own processes by itself.",
                                   command: Killer.sudoCommand(for: s),
                                   confirm: .init(title: "Kill with password", destructive: true) { self.killProtected(s) },
                                   others: [.init(title: "Open sudo shell") { self.openSudoShell(s) }]))
    }

    func confirmQuitGracefully(_ app: NSRunningApplication, name: String) {
        Confirm.ask("Quit \(name)?", "Asks it to quit the normal way, as ⌘Q would.", symbol: "xmark.circle.fill",
                    points: ["It can save first, and may ask you about unsaved work."],
                    undo: "Open it again from the Dock or Launchpad.", button: "Quit") { app.terminate() }
    }

    func confirmForceQuit(pids: [Int32], name: String, vm: Bool = false) {
        var points = ["All \(pids.count) of its processes stop at once, with no chance to save."]
        if vm { points.append("Its virtual machine stops too, like pulling the plug: containers inside it stop.") }
        if let m = memoryText(pids) { points.append(m) }
        Confirm.ask(ConfirmRequest(symbol: "bolt.circle.fill", tint: Self.red, title: "Force quit \(name)?",
                                   message: "Use Quit first: it lets \(name) save.", points: points,
                                   undo: "Cannot be undone. Open \(name) again to start it fresh.",
                                   confirm: .init(title: "Force Quit", destructive: true) { self.forceQuit(pids: pids, name: name) }))
    }

    func confirmDecaffeinate(_ list: [ProcessSample]) {
        let n = list.count
        Confirm.ask(n == 1 ? "Let the Mac sleep?" : "Stop all \(n) caffeinates?",
                    "Stops \(n == 1 ? "this caffeinate" : "these \(n) caffeinates"), which only exist to keep the Mac awake.",
                    symbol: "moon.zzz.fill", tint: Tab.battery.color,
                    points: ["Whatever they were started for (a build, an agent session) keeps running.",
                             "The Mac sleeps again when it is idle, as normal."],
                    undo: "The tool starts a new caffeinate next time it needs one.", button: n == 1 ? "Let it sleep" : "Stop \(n)") {
            self.decaffeinate(list)
        }
    }

    func confirmSlowDown(_ s: ProcessSample, always: Bool) {
        var points = ["It keeps running, on the efficiency cores, with its disk access last in line.",
                      "The apps you are using stay quick; it finishes a little later."]
        if always { points.append("Every new \(s.name) process is lowered as soon as it starts, until you put it back.") }
        if let note = BackgroundCandidates.note(s.name) { points.append(note) }
        Confirm.ask(always ? "Always lower \(s.name)?" : "Lower \(s.displayName)'s priority?", "pid \(s.pid), \(Fmt.pct(s.cpu)) CPU now.",
                    symbol: "tortoise.fill", tint: Tab.rules.color, points: points,
                    undo: "The tortoise button puts it back to normal priority at any time.", button: always ? "Always lower" : "Lower priority") {
            self.slowDown(s, always: always)
        }
    }

    func confirmRestore(_ s: ProcessSample) {
        let ruled = slowRules.contains(s.name)
        Confirm.ask("Put \(s.displayName) back to normal priority?",
                    ruled ? "Also stops lowering new \(s.name) processes." : "It competes with your apps for the performance cores again.",
                    symbol: "hare.fill", tint: Tab.rules.color, button: "Back to normal") { self.restore(s) }
    }

    func confirmInstallUpdate() {
        Confirm.ask("Install v\(update?.version ?? "")?", "Downloads it from GitHub and replaces this copy.",
                    symbol: "arrow.down.circle.fill", tint: Color(hex: "#16a34a"),
                    points: ["Checks the download's signature before installing.", "Quits and reopens in a few seconds.",
                             "Settings and history are kept."], button: "Install and relaunch") { self.installUpdate() }
    }

    /// Rules that kill on their own ask first; the rest are easy to change back.
    func confirmPolicy(_ p: Policy, for s: ProcessSample) {
        switch p {
        case .autoKill, .autoKillOnBattery, .autoKillBelow:
            Confirm.ask("\(p.label) \(s.displayName)?", "From now on System Sentinel stops it by itself when it runs hot\(p == .autoKill ? "" : " under this condition"), without asking.",
                        symbol: "bolt.fill", tint: Theme.heat(100),
                        points: ["It is asked to stop politely first, then forced after 5 seconds.", "Anything unsaved in it is lost each time.",
                                 "Auto-kill stops after 3 kills of the same app in an hour."],
                        undo: "Right-click it and pick Alert me (default), or remove the rule in the Rules tab.", button: p.label, destructive: true) {
                self.setPolicy(p, for: s)
            }
        default:
            setPolicy(p, for: s)
        }
    }

    // MARK: Fixes from insights

    /// Asks first for the fixes that change something; the ones that only open a window go at once.
    /// Storage fixes ask inside `perform`, where their sizes are known.
    func confirmAndPerform(_ f: FixAction) {
        switch f {
        case .quit(let pids, let name):
            var points = ["\(name) is asked to quit the normal way, as ⌘Q would, so it can save first."]
            if let m = memoryText(pids) { points.append(m) }
            Confirm.ask("Quit \(name)?", "A minute later you see what it changed.", symbol: "xmark.circle.fill", points: points,
                        undo: "Open \(name) again to undo.", button: "Quit") { self.perform(f) }
        case .kill(let pids, let label):
            let names = Set(pids.compactMap { sample(pid: $0)?.displayName }).sorted()
            var points = ["Stops \(names.isEmpty ? "\(pids.count) processes" : names.joined(separator: ", ")): politely first, by force after 5 seconds.",
                          "Anything unsaved in them is lost."]
            if !label.contains("caffeinate") { points.append("If they belong to a terminal or agent session you are using, that session ends too.") }
            if let m = memoryText(pids) { points.append(m) }
            Confirm.ask("\(label)?", pids.count == 1 ? "1 process." : "\(pids.count) processes.", symbol: "xmark.octagon.fill",
                        points: points, undo: "Open them again to undo.", button: label, destructive: true) { self.perform(f) }
        case .lowPowerMode:
            Confirm.ask("Turn on Low Power Mode?", "macOS slows the chip a little and cuts background work to save power.",
                        symbol: "leaf.fill", tint: Tab.battery.color,
                        points: ["Asks for your admin password.", "Everything keeps working; heavy work takes a little longer."],
                        undo: "Turn it off in System Settings, Battery, or Control Centre.", button: "Turn on") { self.perform(f) }
        case .leaveHotspot:
            Confirm.ask("Leave the hotspot?", "Turns Wi-Fi off and on, so the Mac rejoins your usual network instead of the phone.",
                        symbol: "wifi.exclamationmark", tint: Tab.network.color,
                        points: ["Connections drop for a few seconds.", "If no usual network is in range, it may rejoin the phone."],
                        undo: "Pick the hotspot again in the Wi-Fi menu.", button: "Leave") { self.perform(f) }
        default:
            perform(f)
        }
    }
}

extension StorageStore {
    /// Asks first, over the page, then runs `action`.
    static func confirm(_ title: String, _ text: String, button: String, destructive: Bool = true, then action: @escaping () -> Void) {
        let trash = button.localizedCaseInsensitiveContains("trash")
        Confirm.ask(title, text, symbol: trash ? "trash.fill" : "sparkles", tint: Tab.storage.color,
                    undo: button.contains("Move to Trash") ? "Put it back from the Trash until the Trash is emptied."
                        : (button == "Empty Trash" ? "Cannot be undone." : nil),
                    button: button, destructive: destructive, then: action)
    }
}
