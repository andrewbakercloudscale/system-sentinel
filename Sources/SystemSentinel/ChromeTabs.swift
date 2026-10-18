import AppKit
import Foundation

/// One open Chrome tab.
struct ChromeTab: Identifiable, Equatable {
    let windowID: String
    let tabID: String
    let title: String
    let url: String
    let active: Bool
    var id: String { "\(windowID)/\(tabID)" }
    var host: String { URL(string: url)?.host ?? url }
}

/// Chrome tab control over AppleScript: list, bring to front, close one tab.
///
/// WHY NOT BY PID: Chrome does not publish which tab a renderer process serves, outside
/// its own Task Manager. So a renderer row offers the tab list (show it, close just that
/// one) and a shortcut to Chrome's Task Manager, which does show the mapping.
/// The first use asks macOS for permission to control Chrome.
@MainActor
enum ChromeTabs {
    static let app = "Google Chrome"

    static var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty == false
    }

    static func list() -> Result<[ChromeTab], ChromeError> {
        let script = """
        set out to ""
        tell application "\(app)"
            repeat with w in windows
                set wid to id of w
                set aid to id of active tab of w
                repeat with t in tabs of w
                    set out to out & wid & tab & (id of t) & tab & (id of t is aid) & tab & (title of t) & tab & (URL of t) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        switch run(script) {
        case .failure(let e): return .failure(e)
        case .success(let text):
            let tabs = text.split(separator: "\n").compactMap { line -> ChromeTab? in
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                // Ids go back into AppleScript source, so only plain numbers are accepted.
                guard f.count >= 5, Int(f[0]) != nil, Int(f[1]) != nil else { return nil }
                return ChromeTab(windowID: f[0], tabID: f[1], title: f[3].isEmpty ? f[4] : f[3], url: f[4], active: f[2] == "true")
            }
            return .success(tabs)
        }
    }

    /// Raises the tab's window and selects the tab, so the owner sees it before closing it.
    static func show(_ t: ChromeTab) -> Result<Void, ChromeError> {
        let script = """
        tell application "\(app)"
            set w to (first window whose id is \(t.windowID))
            set i to 0
            repeat with x in tabs of w
                set i to i + 1
                if id of x is \(t.tabID) then exit repeat
            end repeat
            set active tab index of w to i
            set index of w to 1
            activate
        end tell
        """
        return run(script).map { _ in () }
    }

    /// Closes that one tab. Chrome and every other tab keep running.
    static func close(_ t: ChromeTab) -> Result<Void, ChromeError> {
        let script = """
        tell application "\(app)"
            close (first tab of (first window whose id is \(t.windowID)) whose id is \(t.tabID))
        end tell
        """
        return run(script).map { _ in () }
    }

    /// Opens Chrome's own Task Manager (Window > Task Manager), which maps processes to tabs.
    static func openTaskManager() -> Result<Void, ChromeError> {
        let script = """
        tell application "\(app)" to activate
        tell application "System Events" to tell process "\(app)"
            click menu item "Task Manager" of menu "Window" of menu bar 1
        end tell
        """
        return run(script).map { _ in () }
    }

    private static func run(_ source: String) -> Result<String, ChromeError> {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failure(.message("could not compile")) }
        let out = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                return .failure(.message("Allow System Sentinel to control \(app) in System Settings > Privacy & Security > Automation."))
            }
            if code == -1719 || code == -25211 {
                return .failure(.message("Allow System Sentinel in System Settings > Privacy & Security > Accessibility to open Chrome's Task Manager."))
            }
            return .failure(.message(error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)"))
        }
        return .success(out.stringValue ?? "")
    }
}

enum ChromeError: Error, Equatable {
    case message(String)
    var text: String { if case .message(let m) = self { return m }; return "" }
}
