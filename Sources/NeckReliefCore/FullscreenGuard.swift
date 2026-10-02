import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// macOS never renders a normal window above a native-fullscreen Space, so a window
/// moved onto a display whose active Space is fullscreen lands on that display's
/// desktop Space, invisible. This guard verifies visibility after every move and, when
/// needed, reveals the window by switching Spaces with synthesized ⌃-arrow events
/// (plan D7). If both directions fail, it reports back so the menu bar can say so.
enum FullscreenGuard {

    private static let leftArrow = CGKeyCode(kVK_LeftArrow)
    private static let rightArrow = CGKeyCode(kVK_RightArrow)

    static func ensureVisible(windowID: CGWindowID?, onFail: @escaping (String) -> Void) {
        guard let windowID = windowID else { return }

        // The move takes a moment to register in the window server.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if windowIsOnScreen(windowID) { return }
            postArrow(leftArrow)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if windowIsOnScreen(windowID) { return }
                postArrow(rightArrow)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if windowIsOnScreen(windowID) { return }
                    postArrow(rightArrow) // second nudge, in case one ⌃→ fell short
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if windowIsOnScreen(windowID) { return }
                        onFail("⚠︎ Behind a fullscreen Space — press ⌃→")
                    }
                }
            }
        }
    }

    static func windowIsOnScreen(_ windowID: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { entry in
            (entry[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } == windowID
        }
    }

    private static func postArrow(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
