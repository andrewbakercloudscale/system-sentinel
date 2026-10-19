import AppKit
import SentinelCore
import SwiftUI

extension Model {
    static let crashMarker = CrashMarker(fileURL: Model.supportDir.appendingPathComponent("running"))
    static let crashReports = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")

    /// At launch: did the last run crash? And record exceptions from now on.
    func watchForCrashes() {
        if let started = Model.crashMarker.launch(),
           let report = CrashMarker.report(for: "SystemSentinel", after: started, in: Model.crashReports) {
            lastCrash = report
            Diagnostics.report("crash", "Quit unexpectedly; macOS wrote \(report.lastPathComponent)")
        }
        NSSetUncaughtExceptionHandler { e in
            Diagnostics.report("crash", "Uncaught exception \(e.name.rawValue): \(e.reason ?? "no reason given")")
        }
    }

    /// Everything someone fixing a problem would ask for, as plain text.
    func diagnosticsText(at now: Date = Date()) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines = ["System Sentinel \(Model.appVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))",
                     "macOS \(os), \(Int(cores)) cores, \(ReportDocument.bytes(ProcessInfo.processInfo.physicalMemory)) memory",
                     "Running since \(taskHealth.started.formatted(date: .abbreviated, time: .shortened))",
                     "Own CPU, last minute: " + (SelfGuard.usage.map { String(format: "%.1f%% of one core", $0) } ?? "measuring") + String(format: " (background jobs wait above %.0f%%)", SelfGuard.budget.limit),
                     "", "Background jobs:"]
        let stale = Set(taskHealth.stale(at: now, skip: autoUpdateCheck ? [] : [.updateCheck]))
        for job in TaskHealth.Job.allCases {
            let last = taskHealth.last[job].map { $0.formatted(date: .omitted, time: .standard) } ?? "not yet"
            lines.append("  \(job.title): last \(last)\(stale.contains(job) ? "  (STALLED)" : "")")
        }
        lines += ["", "Errors in the last 7 days:"]
        let recent = errorLog.summary(since: now.addingTimeInterval(-7 * 86_400))
        if recent.isEmpty { lines.append("  none") }
        for e in recent.prefix(30) {
            lines.append("  [\(e.area)] \(e.message) ×\(e.count), last \(e.last.formatted(date: .abbreviated, time: .shortened))")
        }
        if let c = lastCrash { lines += ["", "Last crash report: \(c.path)"] }
        return lines.joined(separator: "\n")
    }
}

/// After a crash, once: what happened and where macOS put its report.
struct CrashBanner: View {
    @ObservedObject var model: Model

    var body: some View {
        if let report = model.lastCrash {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Sentinel quit unexpectedly last time").font(.headline).foregroundStyle(.white)
                    Text("macOS saved a crash report. Copy diagnostics in Settings to send it with the details.")
                        .font(.caption).foregroundStyle(.white.opacity(0.92))
                }
                Spacer(minLength: 6)
                Button("Show report") { NSWorkspace.shared.activateFileViewerSelecting([report]) }
                    .buttonStyle(.plain).font(.callout.weight(.semibold)).foregroundStyle(Theme.heat(100))
                    .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(.white))
                Button { model.lastCrash = nil } label: { Image(systemName: "xmark").foregroundStyle(.white) }
                    .buttonStyle(.plain).help("Dismiss")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.heat(100).gradient))
        }
    }
}

/// Settings: recent failures that happened in the background, and whether every job is running.
struct DiagnosticsCard: View {
    @ObservedObject var model: Model
    @State private var copied = false

    var body: some View {
        let now = Date()
        let errors = model.errorLog.summary(since: now.addingTimeInterval(-7 * 86_400))
        let stale = Set(model.taskHealth.stale(at: now, skip: model.autoUpdateCheck ? [] : [.updateCheck]))
        Card(title: "Diagnostics", symbol: "stethoscope", tint: Tab.settings.color,
             trailing: AnyView(Text(errors.isEmpty && stale.isEmpty ? "all working" : "\(errors.count) error\(errors.count == 1 ? "" : "s") this week")
                .font(.caption.weight(.semibold)).foregroundStyle(errors.isEmpty && stale.isEmpty ? Tab.battery.color : Theme.heat(50)))) {
            Text("BACKGROUND JOBS").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(TaskHealth.Job.allCases, id: \.self) { job in
                    let bad = stale.contains(job)
                    let last = model.taskHealth.last[job]
                    Label("\(job.title): \(last.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now) } ?? "waiting")",
                          systemImage: bad ? "exclamationmark.triangle.fill" : (last == nil ? "clock" : "checkmark.circle.fill"))
                        .font(.caption).foregroundStyle(bad ? Theme.heat(100) : (last == nil ? .secondary : Tab.battery.color))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill((bad ? Theme.heat(100) : Color.secondary).opacity(0.1)))
                        .help(bad ? "Has not finished in over three of its intervals: it may be stuck. Quitting and reopening System Sentinel restarts it." : "Runs every \(Self.every(job.interval)).")
                }
            }
            Text("ERRORS, LAST 7 DAYS").font(.caption2.weight(.bold)).foregroundStyle(.secondary).padding(.top, 4)
            if errors.isEmpty {
                Text("None. Failures that happen in the background (a file that would not save, a scan that timed out) would show here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(errors.prefix(8)) { e in
                HStack(alignment: .top, spacing: 8) {
                    Text(e.area).font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Theme.heat(50)))
                    Text(e.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Text("\(e.count > 1 ? "×\(e.count) · " : "")\(RelativeDateTimeFormatter().localizedString(for: e.last, relativeTo: now))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack {
                Spacer()
                if let url = model.errorLog.fileURL {
                    RowButton(title: "Open log", symbol: "doc.text", color: Tab.settings.color) {
                        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        else { NSWorkspace.shared.open(url.deletingLastPathComponent()) }
                    }
                }
                RowButton(title: copied ? "Copied" : "Copy diagnostics", symbol: copied ? "checkmark" : "doc.on.doc", color: Tab.settings.color) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnosticsText(), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .help("Version, macOS, background jobs and recent errors, ready to paste into a bug report.")
            }
        }
    }

    static func every(_ t: TimeInterval) -> String {
        t < 60 ? "\(Int(t)) s" : t < 3600 ? "\(Int(t / 60)) min" : t < 86_400 ? "\(Int(t / 3600)) hours" : "day"
    }
}
