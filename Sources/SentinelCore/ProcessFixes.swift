import Foundation

/// What can be done about one busy process, beyond killing it: the specific fixes known for
/// it, then the levers every process has (priority, a restart of its app).
public struct ProcessFix: Equatable, Sendable, Identifiable {
    public enum Action: Equatable, Sendable {
        /// Open a System Settings pane.
        case settings(String)
        /// Bring an app forward, where the setting lives inside it.
        case openApp(String)
        /// WindowServer's own window of tweaks with undo.
        case screen
        /// Lower its priority now; `always` lowers every future process of that name too.
        case lowerPriority(always: Bool)
        /// Quit its app the normal way and open it again.
        case quitAndReopen
        /// Advice only: nothing here can do it for you.
        case none
    }

    public let id: String
    public let title: String
    public let detail: String
    public let action: Action
    /// The button's text; nil for advice.
    public let button: String?

    public init(id: String, title: String, detail: String, action: Action, button: String?) {
        self.id = id
        self.title = title
        self.detail = detail
        self.action = action
        self.button = button
    }
}

public enum ProcessFixes {
    /// Everything to offer for a process, specific fixes first.
    /// - Parameters:
    ///   - app: the app it belongs to (a helper's app too), when that app can be quit and reopened.
    ///   - canLower: whether this app may change the process's priority (it must be the user's own).
    ///   - lowered: already at background priority; `always` when a rule keeps it there.
    public static func fixes(for name: String, app: String?, canLower: Bool,
                             lowered: Bool = false, always: Bool = false) -> [ProcessFix] {
        var out = specific(name)
        if canLower {
            if !lowered {
                out.append(ProcessFix(id: "lower", title: "Lower its priority",
                                      detail: "It keeps running on the efficiency cores, with its disk access last in line. Your apps stay quick; it finishes a little later. Undo any time.",
                                      action: .lowerPriority(always: false), button: "Lower now"))
            }
            if !always {
                out.append(ProcessFix(id: "lowerAlways", title: "Always lower \(name)",
                                      detail: "Every \(name) process is lowered as soon as it starts, until you put it back.",
                                      action: .lowerPriority(always: true), button: "Always"))
            }
        }
        if let app {
            out.append(ProcessFix(id: "reopen", title: "Quit and reopen \(app)",
                                  detail: "Clears whatever it has built up since it started: leaked memory, a stuck tab or sync, a loop. It may ask to save, and reopens the windows it normally restores.",
                                  action: .quitAndReopen, button: "Quit and reopen"))
        }
        return out
    }

    /// Whether there is something better to do for this one than lower or restart it.
    public static func hasSpecific(_ name: String) -> Bool { !specific(name).isEmpty }

    static let spotlight = "x-apple.systempreferences:com.apple.Spotlight-Settings.extension"
    static let timeMachine = "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension"
    static let softwareUpdate = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
    static let iCloud = "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings:icloud"
    static let battery = "x-apple.systempreferences:com.apple.Battery-Settings.extension"

    static func specific(_ name: String) -> [ProcessFix] {
        switch name {
        case "WindowServer":
            return [ProcessFix(id: "screen", title: "Give it less to draw",
                               detail: "Transparency, animations, display scaling and windows left open all add to every frame. Each change has an undo.",
                               action: .screen, button: "Optimise the screen")]
        case "mds", "mds_stores", "mdworker", "mdworker_shared", "mdbulkimport", "mdsync", "corespotlightd", "Spotlight":
            return [ProcessFix(id: "spotlight", title: "Keep Spotlight out of busy folders",
                               detail: "Spotlight re-reads every file that changes. Add folders that change all the time (code and build output, virtual machines, Downloads) under Spotlight > Search Privacy, and turn off result types you never use.",
                               action: .settings(spotlight), button: "Spotlight settings")]
        case "backupd", "backupd-helper":
            return [ProcessFix(id: "timeMachine", title: "Back up less often",
                               detail: "Time Machine backs up hourly by default. Options > Back up frequency can make it daily or weekly, and Exclude Items can leave out caches, VMs and build folders.",
                               action: .settings(timeMachine), button: "Time Machine settings")]
        case "bird", "cloudd", "fileproviderd":
            return [ProcessFix(id: "iCloud", title: "Let iCloud Drive finish, or sync less",
                               detail: "It is uploading or downloading. Big folders that change often (code, build output) are the usual cause; move them out of Desktop and Documents if those sync, or turn off apps you do not need syncing.",
                               action: .settings(iCloud), button: "iCloud settings")]
        case "photoanalysisd", "mediaanalysisd", "photolibraryd":
            return [ProcessFix(id: "photos", title: "Let Photos finish while plugged in",
                               detail: "Photos analyses faces, objects and text after imports, mostly when the Mac is idle and charging. It has no deadline, so lowering its priority (below) costs nothing; leaving the Mac charging overnight lets it finish.",
                               action: .none, button: nil)]
        case "softwareupdated", "SoftwareUpdateNotificationManager":
            return [ProcessFix(id: "update", title: "Finish the update",
                               detail: "macOS is downloading or preparing an update. Installing it ends the work.",
                               action: .settings(softwareUpdate), button: "Software Update")]
        case "kernel_task":
            return [ProcessFix(id: "heat", title: "Cool the Mac down",
                               detail: "kernel_task takes CPU time on purpose so other processes get less and the Mac cools. Find what is heating it (the busiest processes here), give it air, and charge with the charger that came with it.",
                               action: .settings(battery), button: "Battery settings")]
        case "com.apple.Virtualization.VirtualMachine", "com.docker.backend", "com.docker.virtualization", "qemu-system-aarch64":
            return [ProcessFix(id: "vm", title: "Give the virtual machine fewer cores",
                               detail: "A VM uses whatever its guest asks for. Stop containers you are not using, and set a CPU limit in Docker Desktop > Settings > Resources (or your VM app's settings).",
                               action: .openApp("Docker"), button: "Open Docker")]
        case "Dropbox", "OneDrive", "Google Drive", "FileProvider":
            return [ProcessFix(id: "sync", title: "Pause syncing",
                               detail: "Sync apps scan and upload every change. Pause sync from its menu bar icon while you work, and exclude folders that change constantly.",
                               action: .openApp(name), button: "Open \(name)")]
        case "coreaudiod":
            return [ProcessFix(id: "audio", title: "Find the app using audio",
                               detail: "coreaudiod mixes sound for every app. An audio app, video call, or plug-in is usually behind it; quitting that app settles it.",
                               action: .none, button: nil)]
        case "Google Chrome", "Google Chrome Helper", "Google Chrome Helper (Renderer)", "Google Chrome Helper (GPU)", "Google Chrome Helper (Plugin)":
            return [ProcessFix(id: "chrome", title: "Find the tab, then let Chrome save energy",
                               detail: "Chrome > Window > Task Manager shows which tab or extension this is; close it. Settings > Performance turns on Energy Saver and Memory Saver, which slow and unload background tabs.",
                               action: .openApp("Google Chrome"), button: "Open Chrome")]
        case "Safari", "com.apple.WebKit.WebContent", "Safari Web Content":
            return [ProcessFix(id: "safari", title: "Close the busy tab",
                               detail: "Each Safari tab runs in its own web content process. Pages with video, ads or live updates keep it busy; closing or reloading the tab ends it.",
                               action: .openApp("Safari"), button: "Open Safari")]
        case "swift-frontend", "swiftc", "swift-build", "clang", "clang++", "cc1plus", "ld", "ld64", "rustc", "cargo", "gcc", "xcodebuild", "XCBBuildService":
            return [ProcessFix(id: "build", title: "It is a build: let it finish",
                               detail: "Compilers use every core on purpose and stop when the build ends. To keep the Mac responsive while building, lower them always (below); to use fewer cores, pass a job limit such as swift build -j 4 or make -j 4.",
                               action: .none, button: nil)]
        case "claude":
            return [ProcessFix(id: "claude", title: "Close sessions you are not using",
                               detail: "Each terminal running Claude Code is one process, and idle ones still tick over. Ending the sessions you have finished with (/exit) adds up.",
                               action: .none, button: nil)]
        default:
            return []
        }
    }
}
