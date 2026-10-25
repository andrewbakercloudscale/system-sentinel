import AppKit
import Foundation

/// TEMP: switches tabs every 2.5 s and logs the longest main-thread stall after each switch.
@MainActor
enum TabBench {
    static var last = CFAbsoluteTimeGetCurrent()
    static var worst = 0.0
    static func start() {
        Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CFAbsoluteTimeGetCurrent()
                worst = max(worst, now - last); last = now
            }
        }
        let tabs = ["Overview", "Checkup", "Processes", "Checkup", "Memory", "Storage", "Checkup", "Network", "Energy", "Events", "Settings", "Checkup"]
        for (i, t) in tabs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15 + Double(i) * 2.5) {
                worst = 0; last = CFAbsoluteTimeGetCurrent()
                Model.current?.goTab = t
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    let line = String(format: "%@ %.0f ms\n", t, worst * 1000)
                    if let h = FileHandle(forWritingAtPath: "/tmp/ss-bench.txt") { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!) }
                    worst = 0
                }
            }
        }
    }
}
