import Foundation

/// Finds newer releases on GitHub. The repository is private, so the GitHub CLI (`gh`, signed
/// in) is tried first; plain HTTPS works once the repository is public.
public enum Updates {
    public static let repo = "andrewbakercloudscale/system-sentinel"

    public struct Release: Equatable, Sendable {
        /// "0.7.1", without the "v".
        public let version: String
        public let tag: String
        public let notes: String
        public let page: URL?
        /// The zip to install, when the release has one.
        public let zip: URL?
        public let published: Date?
    }

    public enum CheckError: Error, Equatable, Sendable {
        case message(String)
        public var text: String { if case .message(let m) = self { return m }; return "" }
    }

    /// Parses `GET /repos/{repo}/releases/latest`.
    public static func parse(_ data: Data) -> Release? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String else { return nil }
        let assets = o["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        let date = (o["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, tag: tag,
                       notes: o["body"] as? String ?? "", page: (o["html_url"] as? String).flatMap(URL.init(string:)),
                       zip: zip, published: date)
    }

    /// True when `a` is a later version than `b`: "0.10.0" is newer than "0.9.3".
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    static func parts(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".")
            .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// The "## New in" bullets as short lines, for a banner or notification.
    public static func highlights(_ notes: String, max: Int = 4) -> [String] {
        var out: [String] = []
        var inNew = false
        for line in notes.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("## ") { inNew = l.lowercased().contains("new"); continue }
            guard inNew, l.hasPrefix("- ") else { continue }
            var t = String(l.dropFirst(2))
            // Keep the bold lead-in ("**Battery**: …" becomes "Battery: …").
            t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            out.append(t)
            if out.count == max { break }
        }
        return out
    }

    /// The GitHub CLI, where Homebrew or the installer put it.
    public static var gh: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Blocks for up to a few seconds: run it off the main thread.
    public static func latest() -> Result<Release, CheckError> {
        if let gh {
            let r = run(gh, ["api", "repos/\(repo)/releases/latest"])
            if r.status == 0, let rel = parse(r.out) { return .success(rel) }
        }
        let r = run("/usr/bin/curl", ["-fsSL", "--max-time", "15", "https://api.github.com/repos/\(repo)/releases/latest"])
        if r.status == 0, let rel = parse(r.out) { return .success(rel) }
        return .failure(.message(gh == nil
            ? "Could not reach GitHub. The repository is private: install GitHub CLI (brew install gh) and run gh auth login."
            : "Could not reach GitHub. Check the network, or run gh auth login in Terminal."))
    }

    /// Downloads the release zip and unpacks it; returns the .app inside.
    public static func download(_ rel: Release) -> Result<URL, CheckError> {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("system-sentinel-\(rel.version)-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var ok = false
        if let gh {
            ok = run(gh, ["release", "download", rel.tag, "--repo", repo, "--pattern", "*.zip", "--dir", tmp.path]).status == 0
        }
        if !ok, let z = rel.zip {
            ok = run("/usr/bin/curl", ["-fsSL", "--max-time", "120", "-o", tmp.appendingPathComponent("app.zip").path, z.absoluteString]).status == 0
        }
        guard ok, let zip = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?.first(where: { $0.hasSuffix(".zip") }) else {
            return .failure(.message("The download failed. Run gh auth login in Terminal, or download it from the release page."))
        }
        let out = tmp.appendingPathComponent("unzipped")
        guard run("/usr/bin/ditto", ["-x", "-k", tmp.appendingPathComponent(zip).path, out.path]).status == 0,
              let app = (try? FileManager.default.contentsOfDirectory(atPath: out.path))?.first(where: { $0.hasSuffix(".app") }) else {
            return .failure(.message("The download could not be unpacked."))
        }
        return .success(out.appendingPathComponent(app))
    }

    /// The script that waits for this app to quit, swaps in the new copy and opens it.
    public static func swapScript(pid: Int32, newApp: String, installedAt: String) -> String {
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(q(installedAt))
        /usr/bin/ditto \(q(newApp)) \(q(installedAt))
        /usr/bin/xattr -cr \(q(installedAt))
        /usr/bin/open \(q(installedAt))
        """
    }

    static func run(_ path: String, _ args: [String]) -> (status: Int32, out: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }
}
