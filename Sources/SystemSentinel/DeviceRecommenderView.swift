import SentinelCore
import SwiftUI

extension Model {
    /// What this Mac has done over the kept history, up to 30 days, from the stores the other
    /// pages already keep: CPU per hour, memory and swap per minute, disk use, power.
    func deviceWorkload(at now: Date = Date()) -> DeviceAdvisor.Workload {
        let hours = min(retentionDays, 30) * 24
        let usage = sentinel.dailyUsage
        // Only hours with at least ten minutes sampled: an hour the app was quit for is not idle.
        let coverage = usage.coverageHourly(at: now, hours: hours)
        let cpu = zip(usage.totalHourly(at: now, hours: hours), coverage).filter { $0.1 >= 600 }.map { $0.0 / 100 }
        let sampledDays = coverage.reduce(0, +) / 86_400

        let since = Int(now.timeIntervalSince1970) - hours * 3600
        let mem = memoryHistory.points.filter { $0.t >= since }
        // Memory in use, not counting swap: macOS fills RAM and swaps a little by design, and
        // whether that hurt shows in the pressure readings instead.
        let need = mem.map { Double($0.used) }
        let pressured = mem.filter { $0.pressure >= MemoryStatus.Pressure.warning.rawValue }.count

        let power = powerHistory.points.filter { $0.t >= since }
        let powerN = power.reduce(0) { $0 + $1.n }
        let onBattery = power.filter(\.onBattery).reduce(0) { $0 + $1.n }

        // The kinds of work, from the apps that did at least a twentieth of the CPU work or
        // held 4 GB of memory.
        let rows = usage.summaries(at: now, hours: hours, group: Model.appKey, name: Model.appName)
        let totalCS = max(rows.reduce(0) { $0 + $1.coreSeconds }, 1)
        var apps = rows.prefix(25).map { (name: $0.name, share: $0.coreSeconds / totalCS) }
        var biggest: [String: UInt64] = [:]
        for p in mem { for a in p.apps { biggest[a.name] = max(biggest[a.name] ?? 0, a.bytes) } }
        apps += biggest.filter { $0.value >= 4 << 30 }.map { (name: $0.key, share: 1.0) }
        let kindApps = DeviceAdvisor.kinds(in: apps)

        let disk = storage.disk
        let diskPoints = storage.history.since(now.addingTimeInterval(-30 * 86_400))
        return DeviceAdvisor.Workload(
            days: sampledDays, cores: Int(cores), memory: ProcessInfo.processInfo.physicalMemory,
            disk: disk?.total ?? 0, diskUsed: disk.map { $0.total - min($0.available, $0.total) } ?? 0,
            diskGrowthPerDay: StorageAnalysis.growthPerDay(diskPoints),
            cpuTypical: DeviceAdvisor.percentile(cpu, 0.5), cpuBusy: DeviceAdvisor.percentile(cpu, 0.95), cpuPeak: cpu.max() ?? 0,
            memoryNeed: UInt64(DeviceAdvisor.percentile(need, 0.95)), memoryPeak: UInt64(need.max() ?? 0),
            pressureShare: mem.isEmpty ? 0 : Double(pressured) / Double(mem.count),
            batteryShare: powerN > 0 ? Double(onBattery) / Double(powerN) : nil,
            kinds: kindApps.keys.sorted(), kindApps: kindApps)
    }

    /// The built-in screen's diagonal in inches, rounded. nil on a desktop Mac or with the lid shut.
    static var builtInScreenInches: Int? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return nil }
        for id in ids.prefix(Int(n)) where CGDisplayIsBuiltin(id) != 0 {
            let mm = CGDisplayScreenSize(id)
            let inches = (mm.width * mm.width + mm.height * mm.height).squareRoot() / 25.4
            return inches > 5 ? Int(inches.rounded()) : nil
        }
        return nil
    }

    /// "Apple M5" from the CPU's brand string.
    static var chipName: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let s = String(cString: buf)
        return s.isEmpty ? "This Mac" : s
    }
}

/// Overview › Next Mac: the MacBook that suits what this Mac has been doing, in a Budget and
/// a Gold Plated version, and whether this one is short of memory or disk today.
struct DeviceRecommenderView: View {
    @ObservedObject var model: Model
    /// Worked out once when the page opens: a month of minutes is too much to sort every tick.
    @State private var workload: DeviceAdvisor.Workload?
    /// "same" (this Mac's screen size), "small" (13 or 14-inch) or "large" (15 or 16-inch).
    @AppStorage("nextMacSize") private var size = "same"

    private var screen: Int? { Model.builtInScreenInches }
    private var large: Bool {
        switch size {
        case "small": return false
        case "large": return true
        default: return (screen ?? 14) >= 15
        }
    }
    private var sizeOptions: [String] {
        [screen.map { "Same as this Mac (\($0)-inch)" } ?? "Same size", "13 or 14-inch", "15 or 16-inch"]
    }
    private var sizeBinding: Binding<String> {
        Binding(get: { size == "small" ? sizeOptions[1] : size == "large" ? sizeOptions[2] : sizeOptions[0] },
                set: { size = $0 == sizeOptions[1] ? "small" : $0 == sizeOptions[2] ? "large" : "same" })
    }

    static let gold = Color(light: "#b45309", dark: "#fbbf24")
    static let budget = Color(light: "#15803d", dark: "#4ade80")

    var body: some View {
        VStack(spacing: 10) {
            // Snapshots render before onAppear runs, so work it out here the first time.
            if let w = workload ?? (Model.snapshotDir != nil ? model.deviceWorkload() : nil) {
                if let a = DeviceAdvisor.advise(w, large: large) {
                    ThisMacCard(w: w, v: a.verdict)
                    HStack(spacing: 8) {
                        Text("Screen size").font(.callout.weight(.semibold))
                        ChipPicker(options: sizeOptions, selection: sizeBinding, color: Self.gold)
                        Spacer(minLength: 0)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        PickCard(title: "Budget", symbol: "dollarsign.circle.fill", tint: Self.budget,
                                 lead: "The least that fits this workload", pick: a.budget)
                        PickCard(title: "Gold Plated", symbol: "crown.fill", tint: Self.gold,
                                 lead: "Room to grow for four or five years", pick: a.gold)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Card(title: "Device Recommender", symbol: "laptopcomputer", tint: Theme.trends) {
                        Text(String(format: "Needs at least %.0f days of history to recommend a Mac; it has %.1f so far. Leave System Sentinel running and check back.",
                                    DeviceAdvisor.minimumDays, w.days))
                            .font(.callout)
                    }
                }
                Text("Based on the last \(Int(min(w.days, 30).rounded())) days this Mac was in use (Settings › History keeps up to 28). Prices are Apple's US list prices before tax, \(DeviceAdvisor.lineUpDate); memory and SSD upgrades are estimated from Apple's usual steps. Memory and SSD cannot be added to a MacBook later, so order what it will need.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .onAppear { workload = model.deviceWorkload() }
    }
}

private struct ThisMacCard: View {
    let w: DeviceAdvisor.Workload
    let v: DeviceAdvisor.Verdict

    var body: some View {
        Card(title: "This Mac's workload", symbol: "laptopcomputer", tint: Theme.trends,
             trailing: AnyView(Text(String(format: "%@ · %d cores · %@ · %@", Model.chipName, w.cores, gb(w.memory), gb(w.disk)))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary))) {
            row("cpu.fill", "Processor", v.cpu, v.cpuText)
            row("memorychip.fill", "Memory", v.memory, v.memoryText)
            row("internaldrive.fill", "Disk", v.disk, v.diskText)
            if let b = w.batteryShare {
                row("battery.75percent", "Battery", .good, String(format: "On battery %.0f%% of the time.", b * 100))
            }
            if !w.kinds.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Workloads seen").font(.callout.weight(.semibold)).frame(width: 110, alignment: .leading)
                    FlowLayout(spacing: 6) {
                        ForEach(w.kinds, id: \.self) { k in
                            Pill(text: w.kindApps[k].map { "\(k.rawValue): \($0)" } ?? k.rawValue, color: Theme.trends)
                        }
                    }
                }
            }
        }
    }

    private func row(_ symbol: String, _ title: String, _ tone: DeviceAdvisor.Verdict.Tone, _ text: String) -> some View {
        let color = tone == .good ? Color(hex: "#16a34a") : tone == .tight ? Color(hex: "#d97706") : Color(hex: "#dc2626")
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            Text(title).font(.callout.weight(.semibold)).frame(width: 86, alignment: .leading)
            Text(metrics: text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func gb(_ b: UInt64) -> String {
        let g = Double(b) / 1_073_741_824
        return g >= 1000 ? String(format: "%.0f TB", (g / 1024).rounded()) : String(format: "%.0f GB", g)
    }
}

private struct PickCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let lead: String
    let pick: DeviceAdvisor.Pick

    var body: some View {
        Card(title: title, symbol: symbol, tint: tint, fill: true) {
            Text(lead).font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(pick.model.name).font(.title3.weight(.bold))
                Text("\(pick.model.chip) chip · \(pick.memoryGB) GB memory · \(size(pick.storageGB)) SSD")
                    .font(.callout.weight(.semibold)).foregroundStyle(tint)
                Text("About $\(pick.price.formatted())").font(.title2.weight(.heavy)).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pick.reasons, id: \.self) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(tint)
                        Text(metrics: r).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func size(_ gb: Int) -> String { gb >= 1024 ? "\(gb / 1024) TB" : "\(gb) GB" }
}
