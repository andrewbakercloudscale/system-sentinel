import Charts
import SentinelCore
import SwiftUI

/// Storage: how full the disk is, how fast it fills, where the space went, and one-click
/// cleanups for the Trash, Downloads, caches, old apps, videos and photo folders.
struct StorageView: View {
    @ObservedObject var model: Model
    @ObservedObject var store: StorageStore

    var body: some View {
        VStack(spacing: 10) {
            if let d = store.disk {
                StorageHero(disk: d, perDay: StorageAnalysis.growthPerDay(store.history.since(Date().addingTimeInterval(-7 * 86_400))))
            }
            if !store.fullAccess { FullAccessNote(store: store) }
            if !store.insights.isEmpty {
                InsightList(model: model, only: store.insights, title: "Storage insights")
            }
            StorageTimeline(store: store)
            WhatGrew(store: store)
            QuickCleanups(store: store)
            DownloadsCard(store: store)
            WhereIsTheSpace(store: store)
            LargeFiles(store: store)
            PackagesCard(store: store)
            VideosCard(store: store)
            PhotoFoldersCard(store: store)
            KnownFolders(store: store)
        }
    }
}

private func gb(_ b: UInt64) -> String { ReportDocument.bytes(b) }
private let storageTint = Tab.storage.color
private let amber = Color(hex: "#d97706")

private func ago(_ d: Date?) -> String {
    guard let d else { return "never opened" }
    return RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
}

/// A file's Finder icon.
private struct FileIcon: View {
    let path: String
    var size: CGFloat = 20
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: size, height: size)
    }
}

/// A small text button for a row: Show, Move…, Trash.
private struct RowButton: View {
    let title: String
    let symbol: String
    var color: Color = storageTint
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(filled ? .white : color)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(filled ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.13))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A share bar behind a number.
private struct StorageBar: View {
    let share: Double
    var color: Color = storageTint
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color.gradient).frame(width: max(3, g.size.width * min(max(share, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

private struct ItemRow: View {
    @ObservedObject var store: StorageStore
    let item: FoundItem
    var subtitle: String?
    /// What it is, on its own line.
    var note: String?
    var trash = true
    var archive = false
    var key: String

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(path: item.path)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(subtitle ?? shortPath(item.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 6)
            Text(gb(item.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
            RowButton(title: "Show", symbol: "magnifyingglass") { store.reveal(item.path) }
            if archive {
                RowButton(title: "Move…", symbol: "externaldrive.badge.plus") { store.archive([item], key: key) }
                    .help("Move it somewhere else, like an external drive")
            }
            if trash {
                RowButton(title: "Trash", symbol: "trash", color: Theme.heat(100)) {
                    if StorageStore.confirm("Move \(item.name) to the Trash?", "\(gb(item.bytes)). You can put it back from the Trash until it is emptied.", button: "Move to Trash") {
                        store.moveToTrash([item], key: key)
                    }
                }
            }
        }
    }
}

private func shortPath(_ p: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let dir = (p as NSString).deletingLastPathComponent
    return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
}

// MARK: Hero

private struct StorageHero: View {
    let disk: DiskSpace
    let perDay: Double?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Gauge(value: min(disk.usedShare, 1), in: 0...1) {
                EmptyView()
            } currentValueLabel: {
                Text("\(Int(disk.usedShare * 100))%").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(.white)
            .scaleEffect(1.35)
            .frame(width: 74, height: 74)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(gb(disk.available)) free").font(.title3.weight(.bold)).foregroundStyle(.white)
                Text("\(gb(disk.used)) of \(gb(disk.total)) used").font(.callout).foregroundStyle(.white.opacity(0.9))
                if disk.purgeable >= 1 << 30 {
                    Text("Includes \(gb(disk.purgeable)) macOS frees by itself when needed").font(.callout).foregroundStyle(.white.opacity(0.9))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let g = perDay {
                    Text((g >= 0 ? "+" : "−") + gb(UInt64(abs(g)))).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white).monospacedDigit()
                    Text("a day, last 7 days").font(.caption).foregroundStyle(.white.opacity(0.85))
                    if let days = StorageAnalysis.daysUntilFull(free: disk.available, perDay: g), days < 365 {
                        Text("full in ~\(Int(days.rounded())) days").font(.caption.weight(.semibold)).foregroundStyle(.white)
                    }
                } else {
                    Text("Growth").font(.callout.weight(.semibold)).foregroundStyle(.white)
                    Text("after a day of readings").font(.caption).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private var colors: [Color] {
        switch disk.level {
        case .ok: return [Color(hex: "#b45309"), Color(hex: "#7c2d12")]
        case .low: return [Color(hex: "#c2410c"), Color(hex: "#9a3412")]
        case .critical: return [Color(hex: "#b91c1c"), Color(hex: "#9f1239")]
        }
    }
}

private struct FullAccessNote: View {
    @ObservedObject var store: StorageStore
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill").font(.title3).foregroundStyle(amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Some folders are hidden by macOS").font(.callout.weight(.semibold))
                Text("Without Full Disk Access, Desktop, Documents, Downloads, Pictures, Movies, Music, the Trash, Mail, Messages and other apps' data are left out, so macOS does not ask about each folder. Grant it once to measure everything. Emptying the Trash still works.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            RowButton(title: "Open settings", symbol: "gearshape", color: amber, filled: true) { store.openFullDiskAccess() }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(amber.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(amber.opacity(0.35)))
    }
}

// MARK: Timeline

private struct StorageTimeline: View {
    @ObservedObject var store: StorageStore
    @AppStorage("storageRange") private var range = "7 days"
    static let ranges: [(String, TimeInterval, Int)] = [("24 hours", 86_400, 600), ("7 days", 7 * 86_400, 3600),
                                                       ("30 days", 30 * 86_400, 6 * 3600), ("90 days", 90 * 86_400, 86_400)]

    struct Bucket: Identifiable {
        let start: Date
        let used: Double
        var id: Date { start }
    }

    private var span: TimeInterval { (Self.ranges.first { $0.0 == range } ?? Self.ranges[1]).1 }
    private var size: Int { (Self.ranges.first { $0.0 == range } ?? Self.ranges[1]).2 }

    var body: some View {
        let points = store.history.since(Date().addingTimeInterval(-span))
        Card(title: "Disk use over time", symbol: "chart.xyaxis.line", tint: storageTint,
             trailing: AnyView(ChipPicker(options: Self.ranges.map(\.0), selection: $range, color: storageTint))) {
            tiles(points)
            chart(Self.buckets(points, size: size))
            jumpList(StorageAnalysis.jumps(points))
        }
    }

    static func buckets(_ points: [StorageHistory.Point], size: Int) -> [Bucket] {
        let g = 1_073_741_824.0
        return Dictionary(grouping: points) { $0.t / size * size }
            .compactMap { t, p in p.last.map { Bucket(start: Date(timeIntervalSince1970: Double(t)), used: Double($0.used) / g) } }
            .sorted { $0.start < $1.start }
    }

    private func tiles(_ points: [StorageHistory.Point]) -> some View {
        let change = (points.last.map { Int64($0.used) } ?? 0) - (points.first.map { Int64($0.used) } ?? 0)
        let perDay = StorageAnalysis.growthPerDay(points)
        let sign = change >= 0 ? "+" : "−"
        return HStack(spacing: 8) {
            StatTile(symbol: change >= 0 ? "arrow.up.right" : "arrow.down.right", color: change > 0 ? amber : Tab.battery.color,
                     value: sign + gb(change.magnitude), label: "change, \(range)")
            StatTile(symbol: "speedometer", color: storageTint, value: perDay.map { ($0 >= 0 ? "+" : "−") + gb(UInt64(abs($0))) } ?? "—",
                     label: "a day on average")
            StatTile(symbol: "calendar.badge.exclamationmark", color: Theme.heat(80), value: forecast(perDay), label: "until full at this pace")
        }
    }

    @ViewBuilder
    private func chart(_ buckets: [Bucket]) -> some View {
        if buckets.count < 2 {
            Text("Collecting: disk use is recorded every 10 minutes and kept for 90 days.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
        } else {
            let now = Date()
            let unit: Calendar.Component = size >= 86_400 ? .day : (size >= 3600 ? .hour : .minute)
            let values = buckets.map(\.used)
            let lo = max(0, (values.min() ?? 0) - 10)
            let hi = (values.max() ?? 0) + 5
            Chart(buckets) { b in
                AreaMark(x: .value("Time", b.start, unit: unit), yStart: .value("GB", lo), yEnd: .value("GB", b.used))
                    .foregroundStyle(storageTint.opacity(0.25))
                LineMark(x: .value("Time", b.start, unit: unit), y: .value("GB", b.used))
                    .foregroundStyle(storageTint)
            }
            .chartYScale(domain: lo...hi)
            .chartXScale(domain: now.addingTimeInterval(-span)...now)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel { if let x = v.as(Double.self) { Text("\(Int(x)) GB") } }.font(.system(size: 9))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel(format: span > 86_400 ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute()).font(.system(size: 9))
                }
            }
            .frame(height: 130)
        }
    }

    @ViewBuilder
    private func jumpList(_ jumps: [StorageAnalysis.Jump]) -> some View {
        if !jumps.isEmpty {
            Text("BIGGEST CHANGES").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).kerning(0.5)
            ForEach(jumps.prefix(5)) { j in
                HStack {
                    Image(systemName: j.bytes > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(j.bytes > 0 ? amber : Tab.battery.color)
                    Text("\(j.bytes > 0 ? "Used" : "Freed") \(gb(j.bytes.magnitude))").font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(j.from.formatted(.dateTime.weekday(.abbreviated).day().hour().minute())) to \(j.to.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func forecast(_ perDay: Double?) -> String {
        guard let d = store.disk, let days = StorageAnalysis.daysUntilFull(free: d.available, perDay: perDay) else { return "not filling" }
        return days >= 365 ? "over a year" : "\(Int(days.rounded())) days"
    }
}

/// Which known folders grew or shrank, from the 6-hourly scans.
private struct WhatGrew: View {
    @ObservedObject var store: StorageStore
    @AppStorage("storageGrewRange") private var range = "7 days"
    static let ranges: [(String, TimeInterval)] = [("24 hours", 86_400), ("7 days", 7 * 86_400), ("30 days", 30 * 86_400)]

    var body: some View {
        let span = Self.ranges.first { $0.0 == range }?.1 ?? 7 * 86_400
        let since = Date().addingTimeInterval(-span)
        let changes = StorageAnalysis.changes(store.history.scans, since: since, min: 100 << 20)
        let scans = store.history.scans.filter { $0.date >= since }
        let top = (store.history.scans.last?.sizes ?? [:]).sorted { $0.value > $1.value }.prefix(5).map(\.key)
        Card(title: "What grew", symbol: "chart.bar.xaxis.ascending", tint: storageTint,
             trailing: AnyView(ChipPicker(options: Self.ranges.map(\.0), selection: $range, color: storageTint))) {
            if changes.isEmpty {
                Text(scans.count < 2 ? "Known folders are measured every 6 hours; changes show after the second measurement."
                                     : "No known folder changed by more than 100 MB in this period.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let biggest = Double(changes.map(\.delta.magnitude).max() ?? 1)
                ForEach(changes.prefix(8)) { c in
                    let p = StoragePlace.named(c.key)
                    HStack(spacing: 8) {
                        Image(systemName: p?.symbol ?? "folder.fill").foregroundStyle(storageTint).frame(width: 18)
                        Text(p?.name ?? c.key).font(.callout).frame(width: 170, alignment: .leading).lineLimit(1)
                        StorageBar(share: Double(c.delta.magnitude) / biggest, color: c.delta > 0 ? amber : Tab.battery.color)
                        Text((c.delta > 0 ? "+" : "−") + gb(c.delta.magnitude)).font(.callout.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(c.delta > 0 ? amber : Tab.battery.color).frame(width: 80, alignment: .trailing)
                        Text("now \(gb(c.to))").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                    }
                }
            }
            if scans.count >= 2 {
                Chart {
                    ForEach(top, id: \.self) { k in
                        ForEach(scans, id: \.t) { s in
                            LineMark(x: .value("Time", s.date), y: .value("GB", Double(s.sizes[k] ?? 0) / 1_073_741_824))
                                .foregroundStyle(by: .value("Folder", StoragePlace.named(k)?.name ?? k))
                                .interpolationMethod(.monotone)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { if let x = v.as(Double.self) { Text("\(Int(x)) GB") } }.font(.system(size: 9))
                    }
                }
                .chartLegend(position: .bottom, spacing: 4)
                .frame(height: 120)
            }
        }
    }
}

// MARK: Cleanups

private struct QuickCleanups: View {
    @ObservedObject var store: StorageStore

    var body: some View {
        let rows = StoragePlace.all.filter { $0.clean != nil }
            .compactMap { p in store.found.places[p.key].map { (p, $0) } }
            .filter { $0.1 >= 20 << 20 }
            .sorted { $0.1 > $1.1 }
        let total = rows.reduce(UInt64(0)) { $0 + $1.1 }
        let trashUnknown = !store.fullAccess
        Card(title: "Quick cleanups", symbol: "sparkles", tint: storageTint,
             trailing: AnyView(Text(total > 0 ? "up to \(gb(total))" : "").font(.callout.weight(.bold)).foregroundStyle(storageTint))) {
            if trashUnknown {
                row(StoragePlace.named("trash")!, bytes: nil)
            }
            ForEach(rows, id: \.0.key) { p, b in row(p, bytes: b) }
            if rows.isEmpty && !trashUnknown {
                Text(store.foundAt == nil ? "Measuring…" : "Nothing worth cleaning: caches and the Trash are small.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Each of these is rebuilt or downloaded again when needed. Nothing personal is touched.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ p: StoragePlace, bytes: UInt64?) -> some View {
        HStack(spacing: 10) {
            SymbolTile(symbol: p.symbol, color: storageTint, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).font(.callout.weight(.semibold))
                Text(p.about).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(bytes.map(gb) ?? "size hidden").font(.callout.weight(.bold)).monospacedDigit()
                .foregroundStyle(bytes == nil ? .secondary : .primary)
            if store.working.contains(p.key) || (p.key == "trash" && store.working.contains("trash")) {
                ProgressView().controlSize(.small).frame(width: 90)
            } else {
                RowButton(title: p.clean == .emptyTrash ? "Empty Trash" : "Clean", symbol: p.clean == .emptyTrash ? "trash.slash" : "sparkles",
                          color: Theme.heat(100), filled: true) {
                    let what = p.clean == .emptyTrash ? "Everything in the Trash is deleted for good." : p.about
                    if StorageStore.confirm(p.clean == .emptyTrash ? "Empty the Trash?" : "Clean \(p.name)?",
                                            what + (bytes.map { " Frees about \(gb($0))." } ?? ""),
                                            button: p.clean == .emptyTrash ? "Empty Trash" : "Clean") {
                        store.clean(p)
                    }
                }
                .frame(minWidth: 90, alignment: .trailing)
            }
        }
    }
}

// MARK: Downloads

private struct DownloadsCard: View {
    @ObservedObject var store: StorageStore
    @AppStorage("downloadsFilter") private var filter = "Over 3 months"
    @State private var picked: Set<String> = []
    @State private var showAll = false
    static let filters = ["All", "Over 3 months", "Installers and archives", "Over 100 MB"]

    var body: some View {
        let now = Date()
        let items = store.found.downloads.filter { i in
            switch filter {
            case "Over 3 months": return Clutter.isStale(i.used ?? i.modified, days: 90, at: now)
            case "Installers and archives": return [.installer, .archive].contains(Clutter.kind(of: i.path))
            case "Over 100 MB": return i.bytes >= 100 << 20
            default: return true
            }
        }
        let total = store.found.downloads.reduce(UInt64(0)) { $0 + $1.bytes }
        let chosen = items.filter { picked.contains($0.path) }
        let chosenBytes = chosen.reduce(UInt64(0)) { $0 + $1.bytes }
        Card(title: "Downloads: \(gb(total)) in \(store.found.downloads.count) items", symbol: "arrow.down.circle.fill", tint: storageTint,
             trailing: AnyView(RowButton(title: "Open", symbol: "folder") { store.reveal(store.home.appendingPathComponent("Downloads").path) })) {
            ChipPicker(options: Self.filters, selection: $filter, color: storageTint)
            if items.isEmpty {
                Text(store.foundAt == nil ? "Measuring…" : "Nothing here matches.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(showAll ? items : Array(items.prefix(12))) { i in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { picked.contains(i.path) },
                                             set: { if $0 { picked.insert(i.path) } else { picked.remove(i.path) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                    FileIcon(path: i.path)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(i.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        Text("Downloaded \(ago(i.used ?? i.modified))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(gb(i.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
                    RowButton(title: "Show", symbol: "magnifyingglass") { store.reveal(i.path) }
                }
            }
            if items.count > 12 {
                Button(showAll ? "Show fewer" : "Show all \(items.count)") { showAll.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
            HStack(spacing: 8) {
                Button(chosen.count == items.count && !items.isEmpty ? "Select none" : "Select all \(items.count)") {
                    if chosen.count == items.count { picked.subtract(items.map(\.path)) } else { picked.formUnion(items.map(\.path)) }
                }
                .disabled(items.isEmpty)
                Spacer()
                if store.working.contains("downloads") { ProgressView().controlSize(.small) }
                RowButton(title: chosen.isEmpty ? "Move to Trash" : "Move \(chosen.count) (\(gb(chosenBytes))) to Trash", symbol: "trash",
                          color: Theme.heat(100), filled: !chosen.isEmpty) {
                    guard !chosen.isEmpty else { return }
                    if StorageStore.confirm("Move \(chosen.count) item\(chosen.count == 1 ? "" : "s") to the Trash?",
                                            "\(gb(chosenBytes)). You can put them back from the Trash until it is emptied.", button: "Move to Trash") {
                        store.moveToTrash(chosen, key: "downloads")
                        picked.subtract(chosen.map(\.path))
                    }
                }
                .disabled(chosen.isEmpty)
                .opacity(chosen.isEmpty ? 0.6 : 1)
            }
        }
    }
}

// MARK: Folders

private struct WhereIsTheSpace: View {
    @ObservedObject var store: StorageStore
    @State private var path = ""

    var body: some View {
        Card(title: "Where the space is", symbol: "folder.fill.badge.questionmark", tint: storageTint, trailing: AnyView(scanButton)) {
            if let p = store.treeProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring every folder in your home folder: \(gb(p.bytes)) in \(p.files.formatted()) files so far. This runs in the background and can take a few minutes.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let t = store.tree {
                let culprits = t.culprits()
                if !culprits.isEmpty {
                    Text("BIGGEST FOLDERS").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).kerning(0.5)
                    let top = Double(culprits.first?.bytes ?? 1)
                    ForEach(culprits, id: \.path) { c in
                        folderRow(c.path, c.bytes, share: Double(c.bytes) / top, full: true)
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    Text("BROWSE").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).kerning(0.5)
                    Button("Home") { path = "" }.buttonStyle(.link).font(.caption)
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                        Text("›").font(.caption).foregroundStyle(.secondary)
                        Button(c) { path = crumbs.prefix(i + 1).joined(separator: "/") }.buttonStyle(.link).font(.caption)
                    }
                    Spacer()
                    Text("\(gb(t.sizes[path] ?? 0))").font(.caption.weight(.semibold))
                }
                let kids = t.children(of: path)
                let parent = Double(t.sizes[path] ?? 1)
                if kids.isEmpty {
                    Text(crumbs.count >= FolderTree.maxDepth ? "Measured \(FolderTree.maxDepth) levels deep. Show it in Finder to look further."
                                                             : "No subfolders over 20 MB.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(kids.prefix(15), id: \.path) { k in
                    folderRow(k.path, k.bytes, share: Double(k.bytes) / max(parent, 1), full: false)
                }
                Text("Measured \(ago(t.at)) in \(Int(t.seconds)) s, \(t.files.formatted()) files. Cloud folders (iCloud Drive, OneDrive…) are left out\(store.fullAccess ? "" : ", and so are your personal folders and other apps' data without Full Disk Access").")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if store.treeProgress == nil {
                Text("Measure every folder to see where the space really is. Runs in the background, about once a day.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var crumbs: [String] { path.isEmpty ? [] : path.split(separator: "/").map(String.init) }

    private var scanButton: AnyView {
        if store.treeProgress != nil {
            return AnyView(RowButton(title: "Stop", symbol: "stop.fill", color: Theme.heat(100)) { store.cancelTree() })
        }
        return AnyView(RowButton(title: store.tree == nil ? "Measure" : "Measure again", symbol: "arrow.clockwise") { store.scanTree() })
    }

    private func folderRow(_ rel: String, _ bytes: UInt64, share: Double, full: Bool) -> some View {
        let abs = store.home.appendingPathComponent(rel).path
        let canOpen = !(store.tree?.children(of: rel).isEmpty ?? true)
        return HStack(spacing: 8) {
            FileIcon(path: abs, size: 18)
            Button {
                if canOpen { path = rel } else { store.reveal(abs) }
            } label: {
                Text(full ? "~/" + rel : (rel as NSString).lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                    .frame(width: full ? 300 : 220, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(canOpen ? "Open this folder below" : "Show in Finder")
            StorageBar(share: share)
            Text(gb(bytes)).font(.callout.weight(.semibold)).monospacedDigit().frame(width: 72, alignment: .trailing)
            RowButton(title: "Show", symbol: "magnifyingglass") { store.reveal(abs) }
        }
    }
}

private struct LargeFiles: View {
    @ObservedObject var store: StorageStore
    @State private var showAll = false

    var body: some View {
        let items = store.largeFiles
        Card(title: "Largest files", symbol: "doc.fill", tint: storageTint,
             trailing: AnyView(Text(items.isEmpty ? "" : "\(items.count) over 500 MB").font(.caption).foregroundStyle(.secondary))) {
            if items.isEmpty {
                Text(store.foundAt == nil ? "Searching with Spotlight…" : "No files over 500 MB in your home folder.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(showAll ? items : Array(items.prefix(10))) { i in
                ItemRow(store: store, item: i, note: Clutter.about(i.path), trash: !(i.path.contains("/Library/")), key: "large")
            }
            if items.count > 10 {
                Button(showAll ? "Show fewer" : "Show all \(items.count)") { showAll.toggle() }.buttonStyle(.link).font(.caption)
            }
            Text("Found with Spotlight. Files inside ~/Library belong to apps: clean them from the app itself, so only Show is offered.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Packages, videos, photos

private struct PackagesCard: View {
    @ObservedObject var store: StorageStore
    @AppStorage("packagesKind") private var kind = "Unused apps"
    static let kinds = ["Unused apps", "Installers", "node_modules"]

    var body: some View {
        let now = Date()
        let (items, sub): ([FoundItem], (FoundItem) -> String) = {
            switch kind {
            case "Installers": return (store.found.installers, { shortPath($0.path) })
            case "node_modules": return (store.found.nodeModules, { "project changed \(ago($0.modified)) · npm install brings it back" })
            default: return (store.found.unusedApps, { "last opened \(ago($0.used))" })
            }
        }()
        let stale = kind == "node_modules" ? items.filter { Clutter.isStale($0.modified, days: 90, at: now) } : items
        let total = stale.reduce(UInt64(0)) { $0 + $1.bytes }
        Card(title: "Packages you can delete", symbol: "shippingbox.fill", tint: storageTint,
             trailing: AnyView(Text(total > 0 ? gb(total) : "").font(.callout.weight(.bold)).foregroundStyle(storageTint))) {
            ChipPicker(options: Self.kinds, selection: $kind, color: storageTint)
            Text(explain).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if stale.isEmpty {
                Text(store.foundAt == nil ? "Searching…" : "None found.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(stale.prefix(12)) { i in ItemRow(store: store, item: i, subtitle: sub(i), key: "packages") }
            if stale.count > 1 {
                HStack {
                    Spacer()
                    RowButton(title: "Move all \(stale.count) (\(gb(total))) to Trash", symbol: "trash", color: Theme.heat(100), filled: true) {
                        if StorageStore.confirm("Move \(stale.count) items to the Trash?", "\(gb(total)): \(stale.prefix(4).map(\.name).joined(separator: ", "))\(stale.count > 4 ? "…" : ""). You can put them back until the Trash is emptied.", button: "Move to Trash") {
                            store.moveToTrash(stale, key: "packages")
                        }
                    }
                }
            }
        }
    }

    private var explain: String {
        switch kind {
        case "Installers": return "Disk images (.dmg), installer packages (.pkg) and .iso files anywhere in your home folder. Once installed, they are rarely needed."
        case "node_modules": return "Dependency folders in JavaScript projects not touched for 3 months. Running npm install in the project brings them back."
        default: return "Apps in Applications not opened for 6 months, by Spotlight's record. Apps from the App Store can be downloaded again for free."
        }
    }
}

private struct VideosCard: View {
    @ObservedObject var store: StorageStore
    @State private var showAll = false

    var body: some View {
        let now = Date()
        let items = store.found.movies
        let stale = items.filter { Clutter.isStale($0.used ?? $0.modified, days: 180, at: now) }
        Card(title: "Videos", symbol: "film.fill", tint: storageTint,
             trailing: AnyView(Text(items.isEmpty ? "" : "\(gb(items.reduce(0) { $0 + $1.bytes })) in \(items.count)").font(.callout.weight(.bold)).foregroundStyle(storageTint))) {
            if !stale.isEmpty {
                Text("\(stale.count) not watched in 6 months: \(gb(stale.reduce(0) { $0 + $1.bytes })). Move them to an external drive or cloud storage to keep them.")
                    .font(.caption).foregroundStyle(amber).fixedSize(horizontal: false, vertical: true)
            }
            if items.isEmpty {
                Text(store.foundAt == nil ? "Searching…" : "No videos over 100 MB.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(showAll ? items : Array(items.prefix(8))) { i in
                ItemRow(store: store, item: i, subtitle: "\(shortPath(i.path)) · watched \(ago(i.used ?? i.modified))", archive: true, key: "videos")
            }
            if items.count > 8 {
                Button(showAll ? "Show fewer" : "Show all \(items.count)") { showAll.toggle() }.buttonStyle(.link).font(.caption)
            }
            if let lib = store.found.places["movies"], lib > 0 {
                Text("The Movies folder holds \(gb(lib)), including iMovie and Final Cut libraries, which keep render files you can delete from inside those apps.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PhotoFoldersCard: View {
    @ObservedObject var store: StorageStore

    var body: some View {
        let now = Date()
        let folders = store.found.photoFolders
        Card(title: "Photo folders to archive", symbol: "photo.stack.fill", tint: storageTint) {
            if folders.isEmpty {
                Text(store.foundAt == nil ? "Searching…" : "No loose photo folders over 200 MB.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(folders.prefix(10)) { f in
                let stale = Clutter.isStale(f.newest, days: 365, at: now)
                HStack(spacing: 8) {
                    FileIcon(path: f.path)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(f.name).font(.callout).lineLimit(1)
                            if stale { Pill(text: "archive", symbol: "archivebox", color: amber) }
                        }
                        Text("\(f.count.formatted()) photos · newest \(ago(f.newest)) · \(shortPath(f.path + "/x"))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(gb(f.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
                    RowButton(title: "Show", symbol: "magnifyingglass") { store.reveal(f.path) }
                    RowButton(title: "Move…", symbol: "externaldrive.badge.plus") {
                        store.archive([FoundItem(path: f.path, bytes: f.bytes)], key: "photos")
                    }
                }
            }
            if let p = store.found.places["pictures"], p >= 5 << 30 {
                Text("Pictures holds \(gb(p)) including the Photos library. In Photos, Settings, iCloud, Optimize Mac Storage keeps full-size originals in iCloud and small copies on the Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Folders whose newest photo is over a year old are marked archive. Move… copies them to a place you pick, such as an external drive, then removes them here.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct KnownFolders: View {
    @ObservedObject var store: StorageStore

    var body: some View {
        let rows = store.found.places.compactMap { k, v in StoragePlace.named(k).map { ($0, v) } }
            .filter { $0.1 >= 50 << 20 }.sorted { $0.1 > $1.1 }
        let top = Double(rows.first?.1 ?? 1)
        Card(title: "Known folders", symbol: "list.bullet.indent", tint: storageTint,
             trailing: AnyView(HStack(spacing: 6) {
                 if store.scanning { ProgressView().controlSize(.small) }
                 RowButton(title: "Rescan", symbol: "arrow.clockwise") { store.scan() }.disabled(store.scanning)
             })) {
            ForEach(rows, id: \.0.key) { p, b in
                HStack(spacing: 8) {
                    Image(systemName: p.symbol).foregroundStyle(storageTint).frame(width: 18)
                    Text(p.name).font(.callout).frame(width: 190, alignment: .leading).lineLimit(1)
                        .help(p.about)
                    StorageBar(share: Double(b) / top)
                    Text(gb(b)).font(.callout.weight(.semibold)).monospacedDigit().frame(width: 72, alignment: .trailing)
                    RowButton(title: "Show", symbol: "magnifyingglass") { store.reveal(store.home.appendingPathComponent(p.path).path) }
                }
            }
            Text(store.foundAt.map { "Measured \(ago($0)); again every 6 hours. Hover a name for what it is." } ?? "Measuring…")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
