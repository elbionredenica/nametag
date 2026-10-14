import AppKit
import ApplicationServices

/// Nametag needs Accessibility access for one thing: reading where Mission Control draws its
/// desktop labels. Naming desktops and the menu bar work without it.
enum Permissions {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt, which adds Nametag to the Accessibility list in System Settings.
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    /// First-launch explanation, shown before macOS's prompt so the request isn't a surprise.
    static func onboardIfNeeded() {
        guard !trusted else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Let Nametag see Mission Control"
        alert.informativeText = """
        To draw your desktop names in Mission Control, Nametag needs Accessibility access. \
        It only reads where Mission Control places its "Desktop" labels — it doesn't read your \
        windows, type, or click anything.

        Turn on Nametag in System Settings → Privacy & Security → Accessibility.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { request() }
    }
}
