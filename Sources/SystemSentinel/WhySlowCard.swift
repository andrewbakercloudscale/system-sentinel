import SentinelCore
import SwiftUI

/// Top of the Processes tab: the last 5 minutes added up by family, and the CPU no row
/// accounts for. The list below ranks single processes, which hides many small ones of one
/// kind and processes too short-lived to be sampled; this is where those show up.
struct WhySlowCard: View {
    @ObservedObject var model: Model
    /// Closed by default: one line with the headline, opened when wanted.
    @AppStorage("whySlow.open.v2") private var open = false

    var body: some View {
        let r = model.recentLoad.report(cores: Int(CPUScale.cores))
        let swap = SwapActivity.of(model.memoryHistory.since(Date().addingTimeInterval(-max(r.span, 60))))
        // Green normal, amber a bit slow, red slow: the worse of the CPU and swapping.
        let level = max(r.busy == nil ? .normal : r.level, swap?.level ?? .normal)
        let hot = level == .slow
        let tint = level == .slow ? Theme.heat(100) : level == .someWhatSlow ? Theme.heat(20) : Theme.heat(0)
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0)).font(.caption.weight(.bold))
                    Image(systemName: hot ? "tortoise.fill" : level == .someWhatSlow ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.33percent")
                    Text("WHY IS IT SLOW? LAST \(max(Int((r.span / 60).rounded()), 1)) MIN").sectionLabel()
                    Spacer()
                    Text(headline(r, swap: swap)).font(.callout.weight(.semibold))
                }
                .foregroundStyle(tint).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip("What used the CPU over the last few minutes, added up by kind, including processes too short-lived for the list")
            if open {
                let top = Array(r.families.prefix(6))
                let peak = max(top.first?.cpu ?? 1, r.unseen ?? 0, 1)
                ForEach(top) { f in
                    row(f.name, cpu: f.cpu, peak: peak, tint: tint,
                        detail: detail(f), note: f.note)
                }
                if let u = r.unseen, u >= 10 {
                    row("Not in any row: kernel and short-lived processes", cpu: u, peak: peak, tint: tint,
                        detail: r.system.map { "\(Fmt.cpu($0)) of the Mac was kernel (system) time" } ?? "",
                        note: "Work the process list cannot show: the kernel, and programs that start and finish between two samples (scripts, status bars, hooks). High system time also comes from heavy disk or network work, or many processes starting at once.")
                }
                if r.started > 0 {
                    starts(r, tint: tint)
                }
                if let swap, showsSwap(swap) {
                    swapping(swap, tint: tint)
                }
                if r.families.isEmpty && (r.unseen ?? 0) < 10 && !(swap.map(showsSwap) ?? false) {
                    Text("Nothing has been busy. If the Mac still feels slow, look at Memory (swap) and Energy (heat).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(level == .normal ? 0.3 : 0.45), lineWidth: hot ? 1.5 : 1))
    }

    /// Many processes starting is load no row shows: every start costs the kernel a fork,
    /// a code signature check and loading libraries, and a loop of `sleep` or `ps` in a
    /// dozen terminals adds up to whole cores.
    private func starts(_ r: RecentLoad.Report, tint: Color) -> some View {
        let rate = r.startsPerSecond
        let busy = rate >= 10
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: busy ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
                    .foregroundStyle(busy ? tint : .secondary)
                Text("\(r.started) processes started in \(period(r.span)), \(rate >= 1 ? "\(Int(rate.rounded())) a second" : "under 1 a second")")
                    .font(.callout.weight(.semibold))
            }
            .tip("Counted from process ids, which macOS hands out in order, so ones that started and finished between two samples count too.")
            if !r.startedBy.isEmpty {
                starters(r)
            }
            if busy {
                Text("That many starts keeps the kernel busy on its own. Usually scripts polling in a loop: status bars, terminal panels, file watchers or a build or test run. Close the ones you do not need.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Top 5 starters. A sample every 5 seconds catches only some of the new processes, so
    /// each one's rate is its share of those caught, times the real rate from the pid count.
    private func starters(_ r: RecentLoad.Report) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                Text("Top starters")
                Text("Share").gridColumnAlignment(.trailing)
                Text("About").gridColumnAlignment(.trailing)
                Text("Caught").gridColumnAlignment(.trailing)
            }
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(r.startedBy) { s in
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        if !s.detail.isEmpty && s.detail != s.name {
                            Text(s.detail).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(Int((s.share * 100).rounded()))%").font(.caption.monospacedDigit())
                    Text(perSecond(s.share * r.startsPerSecond)).font(.caption.monospacedDigit())
                    Text("\(s.caught)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .help(s.detail)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .tip("Who started the new processes. Samples every 5 seconds catch only some of them (Caught); Share is each one's part of those, and About is that share of the real rate. Hover a row for its full command.")
    }

    private func perSecond(_ v: Double) -> String {
        v >= 1 ? "\(Int(v.rounded()))/s" : v >= 0.1 ? String(format: "%.1f/s", v) : "<0.1/s"
    }

    /// "40 seconds" just after launch, "5 minutes" once the window is full.
    private func period(_ span: TimeInterval) -> String {
        span < 90 ? "\(max(Int(span.rounded()), 1)) seconds" : "\(Int((span / 60).rounded())) minutes"
    }

    private func headline(_ r: RecentLoad.Report, swap: SwapActivity?) -> String {
        guard let b = r.busy else { return "measuring…" }
        var s = "Mac \(Fmt.cpu(b)) busy"
        if let sys = r.system, sys >= 0.1 * r.capacity { s += ", \(Fmt.cpu(sys)) kernel" }
        if r.startsPerSecond >= 10 { s += ", \(Int(r.startsPerSecond.rounded())) new processes a second" }
        if let swap, swap.level > .normal { s += ", swapping \(IORow.rate(swap.rate))" }
        return s
    }

    private func showsSwap(_ swap: SwapActivity) -> Bool {
        swap.rate >= 1_000_000 || swap.pressure >= 1 || model.readingBack.contains { $0.rate >= 1_000_000 }
    }

    /// Memory written out to disk and read back: each page read back stalls whoever needed
    /// it, so this is slow the CPU rows cannot show. macOS keeps no swap count per process;
    /// page-ins (which include file reads) and what is out of RAM are the closest per app.
    private func swapping(_ swap: SwapActivity, tint: Color) -> some View {
        let heavy = swap.level > .normal
        let back = model.readingBack.prefix(4).filter { $0.rate >= 500_000 }
            .map { "\($0.name) \(IORow.rate($0.rate))" }.joined(separator: ", ")
        let away = model.memoryApps.filter { $0.outOfRAM >= 512 << 20 }.sorted { $0.outOfRAM > $1.outOfRAM }.prefix(4)
            .map { "\($0.name) \(ReportDocument.bytes($0.outOfRAM))" }.joined(separator: ", ")
        let pressure = swap.pressure >= 2 ? ", memory pressure critical" : swap.pressure == 1 ? ", memory pressure high" : ""
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: heavy ? "exclamationmark.triangle.fill" : "memorychip")
                    .foregroundStyle(heavy ? tint : .secondary)
                Text("Swapping \(IORow.rate(swap.rate)) to and from disk\(pressure)").font(.callout.weight(.semibold))
            }
            if !back.isEmpty {
                Text("Reading memory back most: \(back)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if !away.isEmpty {
                Text("Most memory out of RAM (compressed or in swap): \(away)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if heavy {
                Text("Apps want more memory than the Mac has, so macOS keeps moving it to disk and back, and everything waits. Quit the app with the most out of RAM, or close tabs and windows you do not need.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .tip("Swap traffic for the whole Mac over these minutes. macOS does not count swap per app, so the apps are the ones reading pages back from disk (files included) and holding the most outside RAM.")
    }

    private func detail(_ f: RecentLoad.Family) -> String {
        let who = f.examples.joined(separator: ", ")
        let n = f.processes > 1 ? "\(f.processes) processes" : ""
        return [n, who].filter { !$0.isEmpty }.joined(separator: ": ")
    }

    private func row(_ name: String, cpu: Double, peak: Double, tint: Color, detail: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Theme.heat(min(cpu / peak * 100, 100))).frame(width: g.size.width * min(cpu / peak, 1))
                    }
                }
                .frame(width: 90, height: 6)
                Text(Fmt.cpu(cpu)).font(.callout.monospacedDigit().weight(.semibold)).frame(width: 56, alignment: .trailing)
            }
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .tip(note ?? name)
    }
}
