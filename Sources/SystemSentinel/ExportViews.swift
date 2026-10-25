import AppKit
import SentinelCore
import SwiftUI
import UniformTypeIdentifiers

/// What the Export menu can save. Each picks CSV or JSON; the full report is JSON only.
enum ExportKind: String, CaseIterable {
    case history, events, processes, report

    var title: String {
        switch self {
        case .history: return "History"
        case .events: return "Events"
        case .processes: return "Processes now"
        case .report: return "Full report"
        }
    }

    var formats: [DataExport.Format] { self == .report ? [.json] : [.csv, .json] }
}

extension Model {
    var exportHistory: DataExport.HistoryData {
        let c = Int(cores)
        // Hourly readings for the days before the minute store starts, then minutes.
        let minutes = DataExport.cpuPoints(sentinel.recentUsage, cores: c)
        let hours = DataExport.cpuPoints(sentinel.dailyUsage, cores: c).filter { p in
            minutes.first.map { p.time.addingTimeInterval(3600) <= $0.time } ?? true
        }
        return DataExport.HistoryData(cores: c, cpu: hours + minutes,
                                      memory: DataExport.memory(memoryHistory.points),
                                      power: DataExport.power(powerHistory.points),
                                      storage: DataExport.storage(storage.history.points),
                                      network: DataExport.network(network.throughput.points))
    }

    var exportEvents: [DataExport.Event] { DataExport.events(sentinel.history.entries, cores: Int(cores)) }

    var exportProcesses: [DataExport.Process] {
        let live = min(sentinel.cpuHistory.recorded(at: Date()), 900)
        return DataExport.processes(sentinel.latest, cores: Int(cores),
                                    average: { live >= 900 ? self.average($0, 900) : nil },
                                    gpu: { self.gpuShares[$0] })
    }

    func exportData(_ kind: ExportKind, _ format: DataExport.Format) throws -> Data {
        switch (kind, format) {
        case (.history, .csv): return Data(DataExport.historyCSV(exportHistory).utf8)
        case (.history, .json): return try DataExport.json(exportHistory)
        case (.events, .csv): return Data(DataExport.eventsCSV(exportEvents).utf8)
        case (.events, .json): return try DataExport.json(exportEvents)
        case (.processes, .csv): return Data(DataExport.processesCSV(exportProcesses).utf8)
        case (.processes, .json): return try DataExport.json(exportProcesses)
        case (.report, _):
            let v = ProcessInfo.processInfo.operatingSystemVersion
            let mac = [AboutView.sysctl("hw.model"), AboutView.sysctl("machdep.cpu.brand_string")].compactMap { $0 }.joined(separator: ", ")
            return try DataExport.json(DataExport.Report(
                generated: Date(), app: "\(Model.appVersion) (build \(AboutView.build))",
                macOS: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", mac: mac, cores: Int(cores),
                memoryBytes: ProcessInfo.processInfo.physicalMemory, summary: reportDocument(),
                history: exportHistory, events: exportEvents, processes: exportProcesses))
        }
    }

    /// Asks where, then writes the file and says so in a toast.
    func saveExport(_ kind: ExportKind, _ format: DataExport.Format) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = DataExport.filename(kind == .report ? "report" : kind.rawValue, format, at: Date())
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportData(kind, format).write(to: url, options: .atomic)
            showToast(Toast(ok: true, title: "\(kind.title) exported", detail: url.lastPathComponent))
        } catch {
            showToast(Toast(ok: false, title: "Could not export", detail: error.localizedDescription))
        }
    }
}

/// "Export…": every kind and format, or just `only`.
struct ExportMenu: View {
    @ObservedObject var model: Model
    var only: [ExportKind] = ExportKind.allCases
    var color: Color = Tab.settings.color

    var body: some View {
        Menu {
            ForEach(only, id: \.self) { k in
                if only.count > 1 && k == .report { Divider() }
                ForEach(k.formats, id: \.self) { f in
                    Button("\(k.title) as \(f.rawValue.uppercased())…") { model.saveExport(k, f) }
                }
            }
        } label: {
            Label("Export…", systemImage: "square.and.arrow.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(color.opacity(0.12)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .tip(only.count == 1 ? "Save \(only[0].title.lowercased()) as a CSV or JSON file. You pick where"
                             : "Save history, events, processes or everything as CSV or JSON. You pick where")
        .accessibilityLabel("Export")
    }
}
