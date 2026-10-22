import Foundation

/// One app's use of the graphics chip over the last few minutes.
public struct GPUApp: Equatable, Sendable {
    public let key: String
    public let name: String
    /// Average share of the graphics chip, 0 to 100.
    public let share: Double
    public let pids: [Int32]
    /// The app in front, the one being used.
    public let front: Bool

    public init(key: String, name: String, share: Double, pids: [Int32], front: Bool) {
        self.key = key
        self.name = name
        self.share = share
        self.pids = pids
        self.front = front
    }

    /// What kind of graphics work this is, for the advice that fits.
    public enum Kind: Equatable, Sendable { case screen, browser, ai, other }

    public var kind: Kind {
        let n = (name + " " + key).lowercased()
        if n.contains("windowserver") { return .screen }
        if ["google chrome", "safari", "firefox", "microsoft edge", "arc.app", "brave browser", "opera", "vivaldi", "webkit"].contains(where: n.contains) { return .browser }
        if ["ollama", "lm studio", "lmstudio", "llama", "mlx", "diffusion", "comfyui", "python"].contains(where: n.contains) { return .ai }
        return .other
    }
}

extension Insights {
    /// The graphics chip kept busy: by something in the background, by the screen itself,
    /// or flat out by the app in front. Needs five minutes of readings, so a moment's
    /// animation is not a finding.
    static func gpu(_ i: InsightInput, rel: ([Int32], String?) -> [Insight.Related], byPID: [Int32: ProcessSample]) -> [Insight] {
        guard i.gpuMinutes >= 4.5 else { return [] }
        var out: [Insight] = []
        for a in i.gpuApps.prefix(3) {
            let background = !a.front && a.kind != .screen
            guard a.share >= (background ? 25 : 60) else { continue }
            let pct = Fmt0.pct(a.share)
            var x: Insight
            switch a.kind {
            case .screen:
                x = Insight(id: "gpu-screen", tone: .warning, symbol: "display",
                            title: "Drawing the screen is keeping the graphics chip \(pct) busy",
                            detail: "WindowServer is macOS drawing every window. Its graphics use has averaged \(pct) over the last 5 minutes.")
                x.why = "Large or high refresh rate displays, several displays, transparency and moving windows all cost graphics time. On a laptop this drains the battery and warms the Mac."
                x.steps = ["Optimise the screen: turn off transparency and motion effects, each with an undo.",
                           "Lower an external display's refresh rate from 120 Hz or more to 60 Hz in Displays settings.",
                           "Close windows playing video or animations you are not watching."]
                x.fixes = [.optimiseScreen, .openSettings(.displays)]
            case .browser:
                x = Insight(id: "gpu-\(a.key)", tone: background ? .warning : .info, symbol: "play.rectangle.fill",
                            title: background ? "\(a.name) is using the graphics chip in the background" : "\(a.name) is using \(pct) of the graphics chip",
                            detail: "\(pct) on average over the last 5 minutes\(background ? ", while you are using another app" : ""). Usually a tab playing video, a game, a 3D page or heavy animations.")
                x.why = "Browsers draw pages with the graphics chip. A tab you cannot see can still play video or run a WebGL page, and that keeps the chip, and the battery, busy."
                x.steps = ["Find the tab: in Chrome, Window > Task Manager shows each tab's GPU use; in Safari, look for a tab playing sound or video.",
                           "Close or pause that tab.",
                           "Quit and reopen the browser if no tab explains it."]
                x.fixes = quitFix(a.pids, a.name, byPID)
            case .ai:
                x = Insight(id: "gpu-\(a.key)", tone: background ? .warning : .info, symbol: "brain",
                            title: "\(a.name) is running an AI model on the graphics chip",
                            detail: "\(pct) of the graphics chip on average over the last 5 minutes.")
                x.why = "Local AI models run on the graphics chip. While one is generating, the chip is near flat out, the fans may spin up and a laptop battery drains fast. A loaded model also holds a lot of memory."
                x.steps = ["Let it finish if you started it.",
                           "Otherwise stop it: quit the app, or run `ollama stop <model>` for Ollama.",
                           "A smaller model uses less of the chip and less memory."]
                x.fixes = quitFix(a.pids, a.name, byPID)
            case .other:
                x = Insight(id: "gpu-\(a.key)", tone: background ? .warning : .info, symbol: "square.stack.3d.up.fill",
                            title: background ? "\(a.name) is using the graphics chip in the background" : "\(a.name) is using \(pct) of the graphics chip",
                            detail: "\(pct) on average over the last 5 minutes\(background ? ", while you are using another app" : "").")
                x.why = background
                    ? "An app you are not using should hardly touch the graphics chip. A paused game, a video export or a stuck animation keeps it busy, warming the Mac and draining the battery."
                    : "Games, video editing, 3D and AI work use the graphics chip heavily, and that is expected. It makes the Mac warmer and drains a laptop battery fast."
                x.steps = background
                    ? ["Check what it is doing: an export, a render or a game left running.", "Quit it if it should be idle."]
                    : ["In games, lower the graphics quality or cap the frame rate at 60.", "On battery, turn on Low Power Mode."]
                x.fixes = quitFix(a.pids, a.name, byPID) + (background || !(i.battery?.onBattery ?? false) ? [] : [.lowPowerMode])
            }
            x.related = rel(a.pids, nil)
            out.append(x)
        }
        return out
    }
}

/// One way to make the graphics chip draw less power, for the Graphics card.
public struct GPUSaving: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let fixes: [FixAction]
}

public enum GPUSavings {
    /// What would save graphics power right now, most useful first. `apps` are the last
    /// 5 minutes' averages; empty when nothing is worth doing.
    public static func list(apps: [GPUApp], busy: Double, onBattery: Bool, lowPower: Bool,
                            byPID: [Int32: ProcessSample]) -> [GPUSaving] {
        var out: [GPUSaving] = []
        // The screen always costs a little; only a real share of the chip is worth acting on.
        for a in apps.filter({ $0.share >= ($0.kind == .screen ? 15 : 10) }).prefix(3) {
            let quit = Insights.quitFix(a.pids, a.name, byPID)
            switch a.kind {
            case .screen:
                out.append(GPUSaving(title: "Make the screen cheaper to draw",
                                     detail: "Drawing the screen uses \(Fmt0.pct(a.share)) of the graphics chip. Transparency, motion effects and refresh rates over 60 Hz all add to it.",
                                     fixes: [.optimiseScreen, .openSettings(.displays)]))
            case .browser:
                out.append(GPUSaving(title: "Close the tab that is drawing in \(a.name)",
                                     detail: "\(a.name) uses \(Fmt0.pct(a.share)) of the graphics chip: usually a tab playing video, a game or a 3D page. Chrome's Window > Task Manager shows each tab's GPU use.",
                                     fixes: a.front ? [] : quit))
            case .ai:
                out.append(GPUSaving(title: "Unload \(a.name)'s model when you are done",
                                     detail: "A model generating keeps the graphics chip near flat out. Stop it when you are finished (`ollama stop <model>`, or Eject in LM Studio). A smaller model, or a 4-bit quantised one, does the same work for less power.",
                                     fixes: quit))
            case .other:
                if a.front {
                    out.append(GPUSaving(title: "Cap \(a.name)'s frame rate",
                                         detail: "\(a.name) uses \(Fmt0.pct(a.share)) of the graphics chip. In a game, cap the frame rate at 60 and lower the graphics quality.",
                                         fixes: []))
                } else {
                    out.append(GPUSaving(title: "Quit \(a.name) if it should be idle",
                                         detail: "It uses \(Fmt0.pct(a.share)) of the graphics chip while you work in another app: an export, a render or a game left running.",
                                         fixes: quit))
                }
            }
        }
        if onBattery, !lowPower, busy >= 30 {
            out.append(GPUSaving(title: "Turn on Low Power Mode",
                                 detail: "It lowers the graphics chip's clock speed: a little slower, for much less power and heat.",
                                 fixes: [.lowPowerMode]))
        }
        return out
    }
}
