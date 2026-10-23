import AppKit
import SentinelCore

/// "Share with a friend": an install message through the Mac's own share menu (Messages,
/// Mail, WhatsApp, AirDrop, Notes and anything else that takes text).
@MainActor
enum ShareApp {
    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/\(Updates.repo)/main/install.sh | bash"
    nonisolated static let subject = "System Sentinel: a free menu bar doctor for your Mac"

    static var message: String {
        """
        I've been using System Sentinel, a free Mac app that sits in the menu bar and tells you, in plain English, why your Mac is slow, hot, full or losing battery, with a fix a click away.

        To install it (macOS 14 or later):
        1. Open Terminal: press Cmd+Space, type Terminal, press Return.
        2. Paste this line and press Return:

        \(installCommand)

        It downloads the latest version, puts it in Applications and opens it. Look for the red chip in the menu bar. Run the same line again any time to update.

        More, and the source code: https://github.com/\(Updates.repo)
        """
    }

    private static let delegate = PickerDelegate()

    /// Opens the share menu under the mouse, in the window that was clicked.
    static func show() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible), let view = window.contentView else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let picker = NSSharingServicePicker(items: [message])
        picker.delegate = delegate
        picker.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    private final class PickerDelegate: NSObject, NSSharingServicePickerDelegate {
        // Mail and others take a subject line.
        func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            service?.subject = ShareApp.subject
        }
    }
}
