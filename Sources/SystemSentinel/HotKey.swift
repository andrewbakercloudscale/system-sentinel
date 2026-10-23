import Carbon.HIToolbox
import SentinelCore

/// Control-Option-Command-S opens the window from anywhere. When the menu bar is full, macOS
/// hides the icon behind the notch, and this is the way in that does not depend on it.
/// A Carbon hot key needs no permission, unlike watching every key press.
@MainActor
enum HotKey {
    static let label = "⌃⌥⌘S"
    private static var ref: EventHotKeyRef?

    static func start() {
        guard ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { if let m = Model.current { PopOut.show(m) } } }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5353_4E54), id: 1) // "SSNT"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey | cmdKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Diagnostics.report("hot key", "\(label) is taken by another app (\(status))") }
    }
}
