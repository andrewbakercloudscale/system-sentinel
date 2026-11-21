import Foundation
import SentinelCore

/// Settings an organisation sets with a configuration profile (MDM) for the domain
/// consulting.cloudscale.systemsentinel. A person cannot change them in the app.
/// docs/ENTERPRISE.md lists them with an example profile.
enum Managed {
    private static let domain = (Bundle.main.bundleIdentifier ?? "consulting.cloudscale.systemsentinel") as CFString

    /// Only a value a configuration profile forces. Not UserDefaults: launch arguments
    /// (`--args -DisableSelfUpdate NO`) and `defaults write` would override the profile there.
    private static func on(_ key: String) -> Bool {
        guard CFPreferencesAppValueIsForced(key as CFString, domain) else { return false }
        let v = CFPreferencesCopyAppValue(key as CFString, domain)
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return ["1", "true", "yes"].contains(s.lowercased()) }
        return false
    }

    /// No update checks, installs, reinstalls or "share with a friend": IT deploys versions.
    static var noSelfUpdate: Bool { on("DisableSelfUpdate") }
    /// No "Explain with ChatGPT".
    static var noExplain: Bool { on("DisableExplain") }
    /// The DNS map asks only this Mac's own DNS servers: no 1.1.1.1, 8.8.8.8, DNS over HTTPS
    /// or walk from the root servers, so no name typed in reaches anyone outside.
    static var noPublicDNS: Bool { on("DisablePublicDNSLookups") }
    /// No killing, auto-killing, quit rules or lowering priority of any process.
    static var noProcessControl: Bool { on("DisableProcessControl") }
    /// No admin password prompts at all: no root kills, purge, Low Power Mode, Checkup admin
    /// fixes or removing system launch items, and no sudo commands typed into Terminal.
    static var noAdminActions: Bool { on("DisableAdminActions") }

    /// At launch.
    static func apply() {
        Safety.processControlOff = noProcessControl
        Safety.adminActionsOff = noAdminActions
    }

    static let off = "Turned off by your organisation."
}
