import Foundation

/// CPU is measured per core (100% is one core flat out, so 10 cores reach 1000%), as `ps` and
/// Activity Monitor report it. The app shows it as a share of the whole Mac instead (0 to 100%),
/// so a number never reads as more than everything.
public enum CPUScale {
    public static let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    /// Percent of one core to percent of the whole Mac.
    public static func mac(_ perCore: Double, cores: Double = cores) -> Double { perCore / max(cores, 1) }

    /// "12%", "0.4%", "<0.1%" or "0%" of the whole Mac.
    public static func text(_ perCore: Double, cores: Double = cores) -> String {
        let v = mac(perCore, cores: cores)
        if v <= 0 { return "0%" }
        if v < 0.1 { return "<0.1%" }
        return v >= 10 ? "\(Int(v.rounded()))%" : String(format: "%.1f%%", v)
    }
}
