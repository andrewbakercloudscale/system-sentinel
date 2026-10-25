import SwiftUI
import UserNotifications

/// Pause every alert notification for a while: a meeting, a presentation, a long build.
/// Monitoring, flagging and rules carry on; only the banners wait. Updates, the restart
/// notice, the low battery warning and the permission test still show.
enum Snooze {
    static let key = "alertsPausedUntil"

    static var until: Date? {
        let t = UserDefaults.standard.double(forKey: key)
        return t > Date().timeIntervalSince1970 ? Date(timeIntervalSince1970: t) : nil
    }

    static func pause(until d: Date?) { UserDefaults.standard.set(d?.timeIntervalSince1970 ?? 0, forKey: key) }

    /// Posts an alert unless alerts are paused.
    static func post(_ r: UNNotificationRequest) {
        guard until == nil else { return }
        UNUserNotificationCenter.current().add(r)
    }

    /// Tomorrow at 8:00.
    static var tomorrowMorning: Date {
        let c = Calendar.current
        return c.date(bySettingHour: 8, minute: 0, second: 0, of: c.date(byAdding: .day, value: 1, to: Date()) ?? Date()) ?? Date()
    }
}

/// The bell in the header: pause alerts, and say so while they are paused.
struct SnoozeButton: View {
    @AppStorage(Snooze.key) private var raw: Double = 0

    var body: some View {
        let paused = raw > Date().timeIntervalSince1970
        Menu {
            if paused {
                Button("Resume alerts now") { raw = 0 }
                Divider()
            }
            Button("Pause alerts for 1 hour") { raw = Date().addingTimeInterval(3600).timeIntervalSince1970 }
            Button("Pause alerts for 4 hours") { raw = Date().addingTimeInterval(4 * 3600).timeIntervalSince1970 }
            Button("Pause alerts until tomorrow morning") { raw = Snooze.tomorrowMorning.timeIntervalSince1970 }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: paused ? "bell.slash.fill" : "bell")
                if paused {
                    Text("until \(Fmt.time(Date(timeIntervalSince1970: raw)))").font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(paused ? Tab.events.color : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill((paused ? Tab.events.color : Color.secondary).opacity(0.12)))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(paused ? "Alerts paused" : "Pause alerts")
        .tip(paused ? "Alerts are paused. Monitoring carries on; click to resume" : "Pause alert notifications for a while. Monitoring carries on")
    }
}
