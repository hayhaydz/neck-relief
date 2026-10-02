import AppKit
import ApplicationServices

enum Permissions {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks macOS to show the Accessibility approval prompt (once) if not yet trusted.
    /// Returns the current trust state.
    @discardableResult
    static func promptIfUntrusted() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
