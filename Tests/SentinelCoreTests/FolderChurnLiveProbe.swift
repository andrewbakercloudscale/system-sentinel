import Foundation
import Testing
@testable import SentinelCore

/// FSEvents for real: a few seconds, since it delivers in batches.
@Suite struct FolderChurnLiveProbe {
    @Test func seesRealFileChanges() async throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("fc-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: made + "/code/app/node_modules", withIntermediateDirectories: true)
        // FSEvents reports real paths (/private/var/…); Foundation's symlink resolving drops /private.
        let home = String(cString: realpath(made, nil))
        let dir = home + "/code/app/node_modules"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let c = FolderChurn(home: home)
        c.start()
        defer { c.stop() }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        for i in 0..<120 { try "x".write(toFile: "\(dir)/f\(i).js", atomically: false, encoding: .utf8) }
        try await Task.sleep(nanoseconds: 6_000_000_000)
        #expect(c.top(minimum: 50).first?.path == home + "/code/app/node_modules")
    }
}
