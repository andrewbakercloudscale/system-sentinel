import Foundation

/// Removing launch items that belong to root, without root ever writing into a folder the
/// user can change. A folder the user owns (their temp folder, ~/.Trash) lets any program
/// running as the user plant a symlink there, and root's `mv` or `chown` would follow it into
/// a system folder. So root makes its own private folder (`mktemp -d`, mode 0700, in the
/// sticky /private/tmp), moves each plist into it, then hands the folder to the user and
/// prints its path; the app puts the files in the Trash as the user.
public enum RootStaging {
    public static let prefix = "/private/tmp/systemsentinel-items."

    /// One item: the shell command that stops it (already quoted), its plist and its file name.
    public struct Item: Equatable, Sendable {
        public var stop: String
        public var plist: String
        public init(stop: String, plist: String) { self.stop = stop; self.plist = plist }
    }

    /// A shell word in single quotes.
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The root shell command. It always ends with "<folder> <0 or 1>" on stdout (1 when any
    /// item could not be moved) and exits 0, so the output is read even after a failure.
    public static func command(_ items: [Item], uid: UInt32) -> String {
        var s = "f=0; d=$(/usr/bin/mktemp -d \(prefix)XXXXXXXX) || exit 1"
        for (i, it) in items.enumerated() {
            let name = (it.plist as NSString).lastPathComponent
            s += "; \(it.stop) 2>/dev/null; /bin/mkdir \"$d/\(i)\" && /bin/mv -f \(quote(it.plist)) \"$d/\(i)/\"\(quote(name)) || f=1"
        }
        return s + "; /usr/sbin/chown -R -h \(uid) \"$d\"; echo \"$d $f\""
    }

    /// The folder root made, from the command's output: only the exact shape mktemp gives.
    public static func parse(_ out: String) -> (folder: String, anyFailed: Bool)? {
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.range(of: "\\A/private/tmp/systemsentinel-items\\.[A-Za-z0-9]{8} [01]\\z", options: .regularExpression) != nil else { return nil }
        return (String(t.dropLast(2)), t.hasSuffix("1"))
    }

    /// AppleScript `do shell script ... with administrator privileges` for a command: backslash
    /// first, then double quote, so nothing in the command can end the AppleScript string.
    public static func appleScript(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    /// Runs the command after the admin password prompt. nil when the prompt was cancelled
    /// or refused, or the output is not a folder root made.
    public static func run(_ items: [Item], uid: UInt32 = getuid()) -> (folder: String, anyFailed: Bool)? {
        guard !items.isEmpty else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", appleScript(command(items, uid: uid))]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Puts what root moved into the folder in the Trash, as the user, then removes the
    /// folder. Only a real folder (not a link) that this user now owns is touched.
    public static func trashAll(_ folder: String, uid: UInt32 = getuid()) -> (moved: Int, stuck: Int) {
        let fm = FileManager.default
        var st = stat()
        guard lstat(folder, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == uid else { return (0, 0) }
        var moved = 0, stuck = 0
        for sub in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] {
            let dir = (folder as NSString).appendingPathComponent(sub)
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(f))
                if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil { moved += 1 } else { stuck += 1 }
            }
        }
        // A file the Trash refused stays where it is, so it can still be found.
        if stuck == 0 { try? fm.removeItem(atPath: folder) }
        return (moved, stuck)
    }
}
