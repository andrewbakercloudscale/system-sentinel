import SentinelCore
import SwiftUI
import UserNotifications

extension Model {
    /// Checks each resource alarm against its limit; a notification when one goes off.
    func checkAlarms(_ now: Date) {
        guard Model.snapshotDir == nil else { return }
        let gb = 1_073_741_824.0
        let load = machineAverage(60)
        let swap = Double(memory?.swapUsed ?? 0) / gb
        let pressure = memory?.pressure ?? .normal
        let free = Double(storage.disk?.available ?? UInt64.max) / gb
        let checks: [(ResourceAlarm, Bool, Bool, Double, String, String)] = [
            (.cpu, alarmCPU, load >= alarmCPUPercent, alarmCPUMinutes,
             "Your Mac has been \(Int(load))% busy for \(Int(alarmCPUMinutes)) minutes",
             "Over your \(Int(alarmCPUPercent))% limit. Busiest now: \(top.first.map { "\($0.displayName) at \(Int($0.cpu))% CPU" } ?? "nothing stands out")."),
            (.swap, alarmSwap, swap >= alarmSwapGB, 0,
             "\(String(format: "%.1f", swap)) GB of memory is in swap",
             "Over your \(Int(alarmSwapGB)) GB limit. Largest app: \(memoryApps.first.map { "\($0.name), \(ReportDocument.bytes($0.bytes))" } ?? "unknown"). The Memory tab shows what to quit."),
            (.pressure, alarmPressure, pressure != .normal, alarmPressureMinutes,
             "Memory pressure has been \(pressure.label.lowercased()) for \(Int(alarmPressureMinutes)) minutes",
             "Apps are being squeezed into compressed memory and swap, which slows everything. The Memory tab shows what to quit."),
            (.disk, alarmDisk, free < alarmDiskGB, 0,
             "Only \(String(format: "%.0f", free)) GB of disk space left",
             "Under your \(Int(alarmDiskGB)) GB limit. The Storage tab has one-click cleanups for the Trash, Downloads and caches."),
        ]
        for (alarm, on, over, minutes, title, body) in checks {
            var w = alarmWatches[alarm] ?? AlarmWatch()
            let fire = w.update(over: on && over, holdFor: minutes, at: now)
            alarmWatches[alarm] = w
            guard fire else { continue }
            alarmLog.insert((alarm, now, title), at: 0)
            if alarmLog.count > 20 { alarmLog.removeLast() }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = "info"
            content.sound = .default
            // Grouped together, and a repeat of the same alarm replaces the last one.
            content.threadIdentifier = "alarms"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "alarm-\(alarm.rawValue)", content: content, trigger: nil))
        }
    }
}

/// Settings: the resource alarms, each with its limit and what it reads right now.
struct AlarmsSettingsCard: View {
    @ObservedObject var model: Model
    @Binding var draft: SettingsDraft

    var body: some View {
        Card(title: "Resource alarms", symbol: "bell.and.waves.left.and.right.fill", tint: Tab.events.color) {
            row(on: $draft.alarmCPU, title: "Whole Mac busy", now: "now \(Int(model.machineAverage(60)))%") {
                Stepper("Over \(Int(draft.alarmCPUPercent))% of all cores", value: $draft.alarmCPUPercent, in: 30...100, step: 5)
                Stepper("for \(Int(draft.alarmCPUMinutes)) min", value: $draft.alarmCPUMinutes, in: 1...60)
            }
            row(on: $draft.alarmSwap, title: "Swap used", now: "now \(ReportDocument.bytes(model.memory?.swapUsed ?? 0))") {
                Stepper("Over \(Int(draft.alarmSwapGB)) GB", value: $draft.alarmSwapGB, in: 1...64)
            }
            row(on: $draft.alarmPressure, title: "Memory pressure", now: "now \(model.memory?.pressure.label.lowercased() ?? "…")") {
                Stepper("Warning or worse for \(Int(draft.alarmPressureMinutes)) min", value: $draft.alarmPressureMinutes, in: 1...60)
            }
            row(on: $draft.alarmDisk, title: "Disk space low", now: "now \(ReportDocument.bytes(model.storage.disk?.available ?? 0)) free") {
                Stepper("Under \(Int(draft.alarmDiskGB)) GB free", value: $draft.alarmDiskGB, in: 5...200, step: 5)
            }
            Text("Each alarm sends a notification once, then waits until things are back under the limit (and at least an hour) before it can go off again. Per-app CPU alarms are set at the top of this page; heat and sleep alarms below.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.alarmLog.isEmpty {
                Text("RECENT").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).kerning(0.5)
                ForEach(Array(model.alarmLog.prefix(5).enumerated()), id: \.offset) { _, a in
                    HStack {
                        Text(a.text).font(.caption)
                        Spacer()
                        Text(a.at.formatted(.dateTime.weekday(.abbreviated).hour().minute())).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func row<C: View>(on: Binding<Bool>, title: String, now: String, @ViewBuilder limits: () -> C) -> some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: on).toggleStyle(.switch).labelsHidden().controlSize(.small)
            Text(title).font(.callout.weight(.medium)).frame(width: 130, alignment: .leading)
            HStack(spacing: 10) { limits() }.disabled(!on.wrappedValue).opacity(on.wrappedValue ? 1 : 0.5)
            Spacer()
            Text(now).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

extension Model {
    /// Every material risk at once, for the menu bar colour and the header.
    var health: HealthRAG {
        var s = HealthRAG.Signals()
        s.load = machineAverage(60)
        s.flagged = flagged.count
        s.pressure = memory?.pressure.rawValue ?? 0
        s.swapBytes = memory?.swapUsed ?? 0
        s.disk = storage.disk?.level.rawValue ?? 0
        s.diskFree = storage.disk?.available ?? 0
        s.thermal = thermal.rawValue
        s.battery = battery.map { Double($0.percent) }
        s.onBattery = battery?.onBattery ?? false
        s.checkupProblems = checkup.checks.filter { $0.status == .problem }.count
        return HealthRAG.of(s)
    }
}

/// The header's status: green "All clear", or the risks behind amber and red.
struct HealthChip: View {
    let health: HealthRAG
    /// Opens the tab that explains the first reason: memory pressure opens Memory.
    var open: ((Tab) -> Void)?

    /// Where each reason is explained, by its symbol.
    static func tab(for symbol: String) -> Tab {
        if symbol.hasPrefix("memorychip") { return .memory }
        if symbol.hasPrefix("internaldrive") { return .storage }
        if symbol.hasPrefix("battery") { return .battery }
        if symbol.hasPrefix("stethoscope") { return .checkup }
        if symbol.hasPrefix("thermometer") { return .overview }
        return .processes
    }

    var body: some View {
        if let first = health.reasons.first, let open {
            Button { open(Self.tab(for: first.symbol)) } label: { chip }.buttonStyle(.plain)
        } else {
            chip
        }
    }

    private var chip: some View {
        let c: Color = health.rag == .red ? Theme.heat(100) : (health.rag == .amber ? Color(hex: "#d97706") : Tab.battery.color)
        let text = health.reasons.isEmpty ? "All clear" : health.reasons.prefix(2).map(\.text).joined(separator: " · ")
            + (health.reasons.count > 2 ? " +\(health.reasons.count - 2)" : "")
        return HStack(spacing: 6) {
            Image(systemName: health.reasons.first?.symbol ?? "checkmark.seal.fill").font(.caption.weight(.bold))
            Text(text).font(.callout.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(c)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(c.opacity(0.13)))
        .contentShape(Capsule())
        .tip(health.reasons.isEmpty ? "CPU, memory, disk, heat and battery are all fine"
                                     : health.reasons.map { "\($0.rag == .red ? "Red" : "Amber"): \($0.text)" }.joined(separator: "\n")
                                       + "\nClick to open \(Self.tab(for: health.reasons[0].symbol).title).")
    }
}
