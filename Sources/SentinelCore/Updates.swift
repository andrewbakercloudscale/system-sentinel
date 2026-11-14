import Foundation
import Security

/// Finds newer releases on GitHub: the GitHub CLI (`gh`) when it is installed and signed in,
/// otherwise plain HTTPS to the public API.
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

    /// What changed on GitHub since this version: commits on main after its tag.
    public struct Changes: Equatable, Sendable {
        public struct Commit: Equatable, Sendable, Identifiable {
            public let sha: String
            /// The first line of the message.
            public let title: String
            public let date: Date?
            public var id: String { sha }
        }

        public let ahead: Int
        /// Newest first, at most the 250 GitHub returns.
        public let commits: [Commit]
        public let files: Int
        /// The compare page on GitHub.
        public let page: URL?
    }

    public static let latestFiles = URL(string: "https://github.com/\(repo)/tree/main")!
    public static let releasesPage = URL(string: "https://github.com/\(repo)/releases")!

    /// Parses `GET /repos/{repo}/compare/{base}...{head}`.
    public static func parseChanges(_ data: Data) -> Changes? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ahead = o["ahead_by"] as? Int else { return nil }
        let iso = ISO8601DateFormatter()
        let commits = (o["commits"] as? [[String: Any]] ?? []).compactMap { c -> Changes.Commit? in
            guard let sha = c["sha"] as? String, let info = c["commit"] as? [String: Any] else { return nil }
            let msg = (info["message"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            let date = ((info["author"] as? [String: Any])?["date"] as? String).flatMap { iso.date(from: $0) }
            return .init(sha: String(sha.prefix(7)), title: msg, date: date)
        }
        return Changes(ahead: ahead, commits: commits.reversed(), files: (o["files"] as? [Any])?.count ?? 0,
                       page: (o["html_url"] as? String).flatMap(gitHubURL))
    }

    /// Commits on main since `version`'s tag. Blocks: run it off the main thread.
    public static func changes(since version: String) -> Changes? {
        let tag = "v" + version
        guard isVersionTag(tag) else { return nil }
        let path = "repos/\(repo)/compare/\(tag)...main"
        if let gh {
            let r = run(gh, ["api", path])
            if r.status == 0, let c = parseChanges(r.out) { return c }
        }
        let r = run("/usr/bin/curl", ["-fsSL", "--proto", "=https", "--max-time", "15", "https://api.github.com/" + path])
        return r.status == 0 ? parseChanges(r.out) : nil
    }

    /// Parses `GET /repos/{repo}/releases/latest`.
    public static func parse(_ data: Data) -> Release? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String, isVersionTag(tag) else { return nil }
        let assets = o["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            .flatMap { $0["browser_download_url"] as? String }.flatMap(gitHubURL)
        let date = (o["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, tag: tag,
                       notes: o["body"] as? String ?? "", page: (o["html_url"] as? String).flatMap(gitHubURL),
                       zip: zip, published: date)
    }

    /// "v0.7.1": the tag ends up in a folder name and a command line, so nothing else passes.
    public static func isVersionTag(_ t: String) -> Bool {
        t.range(of: #"^v?[0-9]{1,4}(\.[0-9]{1,4}){1,3}$"#, options: .regularExpression) != nil
    }

    /// Only https links on GitHub are opened or downloaded.
    static func gitHubURL(_ s: String) -> URL? {
        guard let u = URL(string: s), u.scheme == "https", let host = u.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com") else { return nil }
        return u
    }

    /// Checks a downloaded app before it replaces this one: valid signature from the same
    /// signer as the running app (its designated requirement), same bundle id, the version
    /// the release says. Returns why it was refused, or nil when it is fine.
    public static func verify(_ app: URL, version: String, bundleID: String) -> String? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return "The download has no Info.plist." }
        guard info["CFBundleIdentifier"] as? String == bundleID else { return "The download is a different app." }
        guard info["CFBundleShortVersionString"] as? String == version else { return "The download's version does not match the release." }
        var me: SecCode?, mine: SecStaticCode?, req: SecRequirement?, theirs: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &req) == errSecSuccess, let req,
              SecStaticCodeCreateWithPath(app as CFURL, [], &theirs) == errSecSuccess, let theirs else {
            return "The signatures could not be read."
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(theirs, flags, req) == errSecSuccess else {
            return "The download is not signed by the same developer as this copy, so it was not installed."
        }
        return nil
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
        // Once more after a pause: a network that is still coming up (after waking, joining
        // Wi-Fi or a VPN reconnecting) fails the first try and is fine a moment later.
        let first = latestOnce()
        guard case .failure = first else { return first }
        Thread.sleep(forTimeInterval: 3)
        return latestOnce()
    }

    static func latestOnce() -> Result<Release, CheckError> {
        if let gh {
            let r = run(gh, ["api", "repos/\(repo)/releases/latest"])
            if r.status == 0, let rel = parse(r.out) { return .success(rel) }
        }
        let r = run("/usr/bin/curl", ["-fsSL", "--proto", "=https", "--max-time", "15", "https://api.github.com/repos/\(repo)/releases/latest"])
        if r.status == 0, let rel = parse(r.out) { return .success(rel) }
        if r.status == 0 { return .failure(.message("GitHub answered, but not with a release.")) }
        let why = reason(r.err)
        return .failure(.message("Could not reach GitHub" + (why.isEmpty ? "" : " (\(why))") + ". Check the network and try again."))
    }

    /// Downloads the release zip and unpacks it; returns the .app inside.
    public static func download(_ rel: Release) -> Result<URL, CheckError> {
        guard isVersionTag(rel.tag) else { return .failure(.message("The release tag is not a version.")) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("system-sentinel-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var ok = false
        if let gh {
            ok = run(gh, ["release", "download", "--", rel.tag, "--repo", repo, "--pattern", "*.zip", "--dir", tmp.path]).status == 0
        }
        if !ok, let z = rel.zip {
            ok = run("/usr/bin/curl", ["-fsSL", "--proto", "=https", "--max-time", "120", "-o", tmp.appendingPathComponent("app.zip").path, z.absoluteString]).status == 0
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

    /// The script that waits for this app to quit, swaps in the new copy and opens it. The
    /// new copy is staged next to the old one first, so a failed copy leaves the old app.
    public static func swapScript(pid: Int32, newApp: String, installedAt: String) -> String {
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let staged = installedAt + ".update", old = installedAt + ".previous"
        return """
        #!/bin/bash
        set -euo pipefail
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(q(staged)) \(q(old))
        /usr/bin/ditto \(q(newApp)) \(q(staged))
        mv \(q(installedAt)) \(q(old))
        if mv \(q(staged)) \(q(installedAt)); then rm -rf \(q(old)); else mv \(q(old)) \(q(installedAt)); fi
        /usr/bin/open \(q(installedAt))
        """
    }

    static func run(_ path: String, _ args: [String]) -> (status: Int32, out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe(), errPipe = Pipe()
        p.standardOutput = pipe
        p.standardError = errPipe
        let errBuf = ErrBuffer()
        errPipe.fileHandleForReading.readabilityHandler = { errBuf.append($0.availableData) }
        do { try p.run() } catch { return (-1, Data(), error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil
        errBuf.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        return (p.terminationStatus, data, errBuf.text)
    }

    /// Stderr gathered while stdout is read, so neither pipe can fill up and stall the other.
    final class ErrBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); data.append(d.prefix(max(0, 4096 - data.count))); lock.unlock() }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self).split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
    }

    /// "curl: (6) Could not resolve host" becomes "Could not resolve host".
    static func reason(_ err: String) -> String {
        var t = err
        if let r = t.range(of: #"^curl: \(\d+\) "#, options: .regularExpression) { t.removeSubrange(r) }
        return t
    }
}
