import Foundation
import SentinelCore

/// Settings an organisation sets with a configuration profile (MDM) for the domain
/// consulting.cloudscale.systemsentinel. A person cannot change them in the app.
/// docs/ENTERPRISE.md lists them with an example profile.
enum Managed {
    private static func on(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    /// No update checks, installs, reinstalls or "share with a friend": IT deploys versions.
    static var noSelfUpdate: Bool { on("DisableSelfUpdate") }
    /// No "Explain with ChatGPT".
    static var noExplain: Bool { on("DisableExplain") }
    /// The DNS map asks only this Mac's own DNS servers: no 1.1.1.1, 8.8.8.8, DNS over HTTPS
    /// or walk from the root servers, so no name typed in reaches anyone outside.
    static var noPublicDNS: Bool { on("DisablePublicDNSLookups") }
    /// No killing, auto-killing, quit rules or lowering priority of any process.
    static var noProcessControl: Bool { on("DisableProcessControl") }

    /// At launch.
    static func apply() {
        Safety.processControlOff = noProcessControl
    }

    static let off = "Turned off by your organisation."
}
