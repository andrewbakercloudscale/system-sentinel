import Foundation

/// The refresh rates Settings offers, in seconds. 0 means "on every process sample".
public enum RefreshRates {
    public static let defaultProcesses: Double = 5
    public static let defaultEnergy: Double = 30
    public static let defaultSleep: Double = 900

    /// The main sample: processes, CPU, per-core load and everything checked each tick.
    public static let processes: [Double] = [2, 5, 10, 15, 30, 60]
    /// Memory, graphics and battery: every sample, or less often.
    public static let followers: [Double] = [0, 15, 30, 60, 300]
    /// Energy by app, disk and network by app, and what keeps the Mac awake (runs `top`).
    public static let energy: [Double] = [15, 30, 60, 120, 300]
    /// Sleep history, read from the power log.
    public static let sleep: [Double] = [300, 900, 1800, 3600]

    /// The nearest offered value, so a hand-edited default cannot set 0.1 s or a day.
    public static func clamp(_ value: Double, _ choices: [Double]) -> Double {
        choices.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    /// "Every sample", "2 s", "1 min", "15 min".
    public static func label(_ seconds: Double) -> String {
        if seconds <= 0 { return "Every sample" }
        if seconds < 60 { return "\(Int(seconds)) s" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        return "\(Int(seconds / 3600)) h"
    }
}
