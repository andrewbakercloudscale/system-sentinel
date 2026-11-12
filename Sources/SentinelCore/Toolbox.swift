import Foundation

/// Fixed scripts behind Quick fixes that run as the user. Nothing read off the Mac goes in.
public enum ToolboxScript {
    /// Asks the open ones of these apps to quit (they save as usual; one that is not open is
    /// not touched, so AppleScript never asks where it is) and waits up to 15 seconds. Exit 1
    /// if one is still open, so nothing is changed under a running app. Each is its process
    /// name and its app name.
    static func quit(_ apps: [(process: String, app: String)]) -> String {
        apps.map { "/usr/bin/pgrep -x '\($0.process)' >/dev/null && /usr/bin/osascript -e 'quit app \"\($0.app)\"' >/dev/null 2>&1; " }.joined()
            + "for i in $(/usr/bin/seq 1 30); do " + apps.map { "/usr/bin/pgrep -x '\($0.process)' >/dev/null || " }.joined()
            + "break; /bin/sleep 0.5; done; "
            + apps.map { "/usr/bin/pgrep -x '\($0.process)' >/dev/null && exit 1; " }.joined()
    }

    /// Mail's search index: Mail quits, the Envelope Index files go to the Trash (in a
    /// dated folder, so it can be put back), and Mail opens and rebuilds it. Needs Full Disk
    /// Access to reach ~/Library/Mail (exit 2 without it).
    public static let rebuildMailIndex = quit([("Mail", "Mail")])
        + "ls ~/Library/Mail/V*/MailData/'Envelope Index' >/dev/null 2>&1 || exit 2; "
        + "d=~/.Trash/\"Mail index $(/bin/date +%Y-%m-%d-%H%M%S)\"; /bin/mkdir -p \"$d\" && /bin/mv ~/Library/Mail/V*/MailData/'Envelope Index'* \"$d\"/ || exit 3; "
        + "/usr/bin/open -a Mail"

    /// The recent apps, documents and servers lists (Apple menu, Finder, each app's Open
    /// Recent). Favourites and the Finder sidebar are kept.
    public static let clearRecentItems = "cd ~/Library/Application\\ Support/com.apple.sharedfilelist || exit 2; "
        + "/bin/rm -f com.apple.LSSharedFileList.RecentApplications.sfl* com.apple.LSSharedFileList.RecentDocuments.sfl* "
        + "com.apple.LSSharedFileList.RecentServers.sfl* com.apple.LSSharedFileList.RecentHosts.sfl*; "
        + "/bin/rm -rf com.apple.LSSharedFileList.ApplicationRecentDocuments/*; /usr/bin/killall sharedfilelistd 2>/dev/null; true"

    /// Microsoft 365 apps whose sign-in is reset.
    static let officeApps: [(process: String, app: String)] = [
        ("Microsoft Outlook", "Microsoft Outlook"), ("Microsoft Word", "Microsoft Word"), ("Microsoft Excel", "Microsoft Excel"),
        ("Microsoft PowerPoint", "Microsoft PowerPoint"), ("Microsoft OneNote", "Microsoft OneNote"), ("MSTeams", "Microsoft Teams"),
        ("OneDrive", "OneDrive"),
    ]

    /// Microsoft's cached sign-in tokens, the keychain items Microsoft's own Office Reset
    /// removes for "Reset credentials": the apps quit first, then sign in fresh. Company
    /// Portal and the device's Platform SSO registration are not touched.
    public static let resetMicrosoftSignIn: String = {
        let generic = ["Microsoft Office Identities Cache 2", "Microsoft Office Identities Cache 3",
                       "Microsoft Office Identities Settings 2", "Microsoft Office Identities Settings 3",
                       "Microsoft Office Ticket Cache", "com.microsoft.adalcache", "Microsoft Teams Identities Cache",
                       "MicrosoftOfficeRMSCredential", "MicrosoftOfficeIRMCredential"]
        // An item can exist several times: delete until there is none left.
        let del = generic.map { "while /usr/bin/security delete-generic-password -l '\($0)' >/dev/null 2>&1; do :; done; " }.joined()
            + "while /usr/bin/security delete-generic-password -G 'MSOpenTech.ADAL.1' >/dev/null 2>&1; do :; done; "
            + ["msoCredentialSchemeADAL", "msoCredentialSchemeLiveId"].map { "while /usr/bin/security delete-internet-password -s '\($0)' >/dev/null 2>&1; do :; done; " }.joined()
        return quit(officeApps) + del + "true"
    }()
}
