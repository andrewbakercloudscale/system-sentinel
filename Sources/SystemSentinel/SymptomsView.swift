import AppKit
import SentinelCore
import SwiftUI

/// What the symptom checks read off the Mac beyond the numbers the app already keeps.
struct SymptomProbes {
    var privacy: [PrivacyGrant]?
    var blockedApps: [BlockedApp] = []
    var bluetooth: BluetoothState?
    var displays: DisplaySetup?
    var panic: String?
    var at: Date?
}

extension CheckupStore {
    /// Re-reads the probes when a symptom is opened, unless they are under five minutes old.
    func refreshProbes() {
        guard !running, probes.at.map({ Date().timeIntervalSince($0) >= 300 }) ?? true else { return }
        Task.detached(priority: .utility) {
            let read = await CheckupStore.readProbes()
            await MainActor.run { self.probes = read }
        }
    }

    nonisolated static func readProbes() async -> SymptomProbes {
        async let privacy = readPrivacy()
        async let blocked = blockedApps()
        async let bluetooth = SymptomParse.bluetooth(Data(sh("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 20).utf8))
        async let panic = latestPanic()
        async let displays = DisplaySetup(
            displays: DisplayPixels.parse(Data(sh("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"], timeout: 15).utf8)),
            devices: SymptomParse.thunderbolt(Data(sh("/usr/sbin/system_profiler", ["SPThunderboltDataType", "-json"], timeout: 15).utf8)),
            chip: sh("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"], timeout: 5).trimmingCharacters(in: .whitespacesAndNewlines))
        return await SymptomProbes(privacy: privacy, blockedApps: blocked, bluetooth: bluetooth, displays: displays, panic: panic, at: Date())
    }

    /// The microphone and camera rows of the person's privacy database. It needs Full Disk
    /// Access; without it sqlite3 is refused and this is nil.
    nonisolated static func readPrivacy() -> [PrivacyGrant]? {
        let db = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let out = sh("/usr/bin/sqlite3", ["-readonly", db,
                                          "select service, client, auth_value from access where service in ('kTCCServiceMicrophone','kTCCServiceCamera')"], timeout: 5)
        if out.contains("unable to open") || out.contains("authorization denied") || out.contains("Error") { return nil }
        return SymptomParse.privacy(out) { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        .sorted { ($0.name.lowercased(), $0.service) < ($1.name.lowercased(), $1.service) }
    }

    /// Apps in Applications that were downloaded, never opened with approval, and fail
    /// Gatekeeper: the ones macOS calls damaged. Only unapproved apps are assessed, as each
    /// assessment takes a moment.
    nonisolated static func blockedApps() -> [BlockedApp] {
        let fm = FileManager.default
        let dirs = ["/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        let apps = dirs.flatMap { d in ((try? fm.contentsOfDirectory(atPath: d)) ?? []).filter { $0.hasSuffix(".app") }.map { d + "/" + $0 } }
        let unapproved = apps.filter { path in
            var buf = [UInt8](repeating: 0, count: 256)
            let n = getxattr(path, "com.apple.quarantine", &buf, buf.count, 0, 0)
            guard n > 0 else { return false }
            return !SymptomParse.approved(String(decoding: buf.prefix(n), as: UTF8.self))
        }
        return unapproved.prefix(12).filter { SymptomParse.rejected(sh("/usr/sbin/spctl", ["-a", "-vv", "-t", "exec", $0], timeout: 15)) }
            .map { BlockedApp(name: fm.displayName(atPath: $0).replacingOccurrences(of: ".app", with: ""), path: $0) }
    }

    /// The newest kernel panic of the last 30 days, in a sentence.
    nonisolated static func latestPanic() -> String? {
        let dir = URL(fileURLWithPath: "/Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.filter { $0.lastPathComponent.hasPrefix("panic") }
            .compactMap { u -> (URL, Date)? in
                guard let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      d >= Date().addingTimeInterval(-30 * 86_400) else { return nil }
                return (u, d)
            }
        guard let newest = dated.max(by: { $0.1 < $1.1 }), let text = try? String(contentsOf: newest.0, encoding: .utf8) else { return nil }
        return SymptomParse.panic(text)
    }
}

extension Model {
    /// Everything the symptom checks need, from what the app already measures.
    func vitals() -> Vitals {
        var v = Vitals()
        v.cpuBusy = machineAverage(60)
        v.pressure = memory?.pressure ?? .normal
        v.swap = memory?.swapUsed ?? 0
        v.thermal = thermal.rawValue
        let groups = Dictionary(grouping: top, by: { Model.appKey($0.path) })
        v.busyApps = groups.compactMap { key, list -> AppLoad? in
            guard let any = list.first, any.pid != getpid(), Safety.canKillManually(any) else { return nil }
            let cpu = list.reduce(0) { $0 + average($1, 60) }
            return cpu >= 10 ? AppLoad(name: Model.appName(key), amount: cpu, pids: list.map(\.pid)) : nil
        }
        .sorted { $0.amount > $1.amount }
        v.memoryApps = memoryApps.filter { $0.sample.pid != getpid() && Safety.canKillManually($0.sample) }.prefix(5)
            .map { AppLoad(name: $0.name, amount: Double($0.bytes), pids: $0.pids) }
        v.battery = battery
        v.energyApps = energy.filter { $0.power >= 5 }.prefix(5).map { AppLoad(name: $0.name, amount: $0.power, pids: $0.pids) }
        v.disk = storage.disk
        v.networkChecks = checkup.checks.filter { $0.area == .network }
        v.sleep = sleepReport
        v.blockers = blockers
        let p = checkup.probes
        v.privacy = p.privacy
        v.blockedApps = p.blockedApps
        v.bluetooth = p.bluetooth
        v.displaySetup = p.displays
        v.panic = p.panic
        let all = sentinel.latest
        func cpu(_ names: Set<String>) -> Double {
            all.filter { names.contains(URL(fileURLWithPath: $0.path).lastPathComponent) }.reduce(0) { $0 + average($1, 60) }
        }
        v.bluetoothCPU = cpu(["bluetoothd"])
        v.syncCPU = cpu(["bird", "cloudd"])
        v.windowServerCPU = cpu(["WindowServer"])
        v.restartChecks = checkup.checks.filter { $0.id == "panics" }
        v.crashChecks = checkup.checks.filter { $0.id == "crashes" }
        return v
    }
}

/// Everything that needs a look, in one place: what the checks found, what the symptoms
/// found from live numbers, and the insights. Ignored ones left out. Checkup lists it; the
/// tab badge and the Overview's banner count it.
struct Attention {
    var checks: [Check] = []
    var symptoms: [(symptom: Symptom, check: Check)] = []
    var insights: [Insight] = []
    /// Insights worth knowing but not a problem.
    var notes: [Insight] = []

    var problems: Int {
        checks.filter { $0.status == .problem }.count + symptoms.filter { $0.check.status == .problem }.count
            + insights.filter { $0.tone == .critical }.count
    }
    var count: Int { checks.count + symptoms.count + insights.count }
}

extension Insight {
    /// What Ignore remembers for an insight. One about particular processes is ignored for
    /// good, like an app the person runs on purpose; a general one for a day.
    var ignoreKey: String { "insight:" + id }
    var ignoreFor: TimeInterval { related.isEmpty ? 86_400 : .infinity }
}

extension Model {
    /// The insight ids (as prefixes) that report the same thing as a symptom finding.
    static func sameAsInsight(_ c: Check) -> [String] {
        let map: [String: [String]] = ["-blockers": ["blockers"], "-hot": ["thermal"], "-draw": ["drain-"],
                                       "-free": ["disk-low", "disk-critical"], "-wakes": ["darkwakes"],
                                       "-asleep": ["sleepdrain"], "-memory": ["mem-thrash"]]
        return map.first { c.id.hasSuffix($0.key) }?.value ?? []
    }

    func attention() -> Attention {
        let ignored = checkup.ignoredKeys
        var a = Attention()
        a.checks = checkup.checks.filter { $0.status >= .warning && !ignored.contains($0.ignoreKey) }
        // A symptom finding that is one of the checks above is counted there.
        let listed = Set(a.checks.map(\.ignoreKey))
        var open = insights.filter { !ignored.contains($0.ignoreKey) }
        // Some symptom findings and insights say the same thing. Show it once, as the
        // insight (it lists the processes); ignoring either hides both.
        a.symptoms = Diagnose.found(vitals()).filter { f in
            guard !listed.contains(f.check.ignoreKey) else { return false }
            let same = Model.sameAsInsight(f.check)
            if ignored.contains(f.check.ignoreKey) {
                open.removeAll { i in same.contains { i.id.hasPrefix($0) } }
                return false
            }
            if same.contains(where: { p in ignored.contains { $0.hasPrefix("insight:" + p) } }) { return false }
            return !open.contains { i in same.contains { i.id.hasPrefix($0) } }
        }
        a.insights = open.filter { $0.tone >= .warning }
        a.notes = open.filter { $0.tone < .warning }
        return a
    }
}

/// The top of the Checkup tab: what the Mac found wrong on its own, and a row of symptoms to
/// say what feels wrong. One symptom opens at a time, so the tab stays short.
struct SymptomsCard: View {
    @ObservedObject var model: Model
    @ObservedObject var store: CheckupStore
    /// Taken by the Checkup page when it opens, so the list does not move while it is read.
    let attention: Attention
    let vitals: Vitals
    @Binding var open: Symptom?
    let row: (Check) -> AnyView
    @State private var openInsights: Set<String> = []
    @State private var showNotes = false
    private let tint = Tab.checkup.color

    var body: some View {
        let v = vitals
        let found = attention.symptoms
        let ignoredCount = store.ignoredKeys.count
        let flagged = Dictionary(found.map { ($0.symptom, $0.check.status) }, uniquingKeysWith: max)
        Card(title: "What's wrong?", symbol: "stethoscope", tint: tint) {
            if found.isEmpty && attention.insights.isEmpty {
                Label("Nothing wrong found on its own right now. If something feels wrong, pick it below.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(Tab.battery.color).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("FOUND ON ITS OWN").sectionLabel()
                ForEach(found, id: \.symptom) { f in
                    Button { toggle(f.symptom) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: f.check.status == .problem ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .font(.title3).foregroundStyle(color(f.check.status)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.check.title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                                Text(f.symptom.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            IgnoreButton(subject: f.check.subject != nil) { withAnimation { store.ignore(f.check) } }
                            Text(open == f.symptom ? "Hide" : "Fix it").font(.caption.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(color(f.check.status)))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tip("Show what was found and how to fix it")
                }
            }
            ForEach(attention.insights) { i in insight(i) }
            if !attention.notes.isEmpty {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showNotes.toggle() } } label: {
                    Label("Worth knowing (\(attention.notes.count))", systemImage: showNotes ? "chevron.down" : "chevron.right")
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .tip("Findings that are not problems: patterns and things to be aware of")
                if showNotes { ForEach(attention.notes) { i in insight(i) } }
            }
            if ignoredCount > 0 {
                HStack(spacing: 6) {
                    Text("\(ignoredCount) ignored").font(.callout).foregroundStyle(.secondary)
                    Button("Show again") { withAnimation { store.showIgnoredAgain() } }
                        .buttonStyle(.link).font(.callout)
                        .tip("Flag everything you have ignored again")
                }
            }
            Text("OR SAY WHAT FEELS WRONG").sectionLabel().padding(.top, 4)
            FlowLayout(spacing: 6) {
                ForEach(Symptom.allCases) { s in chip(s, flagged[s]) }
            }
            if let s = open { panel(s, v) }
        }
    }

    private func insight(_ i: Insight) -> some View {
        InsightCard(model: model, insight: i, expanded: Binding(
            get: { openInsights.contains(i.id) || (Model.snapshotDir != nil && i.tone >= .warning) },
            set: { if $0 { openInsights.insert(i.id) } else { openInsights.remove(i.id) } }),
            onIgnore: { withAnimation { store.ignore(key: i.ignoreKey, for: i.ignoreFor) } })
    }

    private func toggle(_ s: Symptom) {
        withAnimation(.easeInOut(duration: 0.2)) { open = open == s ? nil : s }
        if open != nil { store.refreshProbes() }
    }

    private func chip(_ s: Symptom, _ status: Check.Status?) -> some View {
        let on = open == s
        return Button { toggle(s) } label: {
            HStack(spacing: 5) {
                Image(systemName: s.symbol)
                Text(s.rawValue)
                if let status { Circle().fill(on ? .white : color(status)).frame(width: 7, height: 7) }
            }
            .font(.callout.weight(on ? .semibold : .regular))
            .foregroundStyle(on ? Color.white : Color.primary.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(on ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.06))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tip(status.map { _ in "Something was found here" } ?? "Check this")
    }

    private func panel(_ s: Symptom, _ v: Vitals) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(s.question).font(.headline)
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.2)) { open = nil } } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .tip("Close")
            }
            ForEach(Diagnose.checks(s, v)) { c in row(c) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.25)))
    }

    private func color(_ s: Check.Status) -> Color {
        s == .problem ? Theme.heat(100) : Color(hex: "#d97706")
    }
}

/// Ignore, beside a finding: for good when it is about a particular app, for a day otherwise.
struct IgnoreButton: View {
    /// Whether the finding names a particular app or process.
    let subject: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Ignore").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().strokeBorder(Color.secondary.opacity(0.5)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .tip(subject ? "It is on purpose: stop flagging this. Something else causing it still shows. Show again on Checkup brings it back"
                     : "Hide this for a day. Show again on Checkup brings it back")
    }
}
