import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.hayhaydz.neckrelief", category: "focus")

/// Puts keyboard focus on other apps' windows. AX-based throughout:
/// NSRunningApplication.activate() alone silently no-ops from a background app
/// on macOS 14+.
@MainActor
final class FocusController {

    private let discovery: WindowDiscovery
    private let displayManager: DisplayManager

    init(discovery: WindowDiscovery, displayManager: DisplayManager) {
        self.discovery = discovery
        self.displayManager = displayManager
    }

    /// Raises a specific window element, makes it the app's focused/main window,
    /// and activates the app.
    func focus(_ element: AXUIElement, pid: pid_t) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, element)
        NSRunningApplication(processIdentifier: pid)?.activate()
        log.notice("focus → \(Format.appName(pid), privacy: .public)")
    }

    /// Focuses the window of `pid` nearest `frameHint` (the captured "revealed"
    /// window), falling back to plain app activation when the app exposes no
    /// usable windows.
    func focusWindow(pid: pid_t, frameHint: CGRect?) {
        let candidates = discovery.windows(of: pid).filter { !$0.isMinimized }
        let target = candidates.min(by: { a, b in
            distance(a.frame, frameHint ?? .zero) < distance(b.frame, frameHint ?? .zero)
        })
        if let target = target {
            focus(target.element, pid: pid)
            return
        }
        log.notice("focus fallback: no AX windows for \(Format.appName(pid), privacy: .public), activating app")
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// Last-resort refocus when nothing was captured: frontmost suitable window on
    /// the display the user is staying on. Called at move completion (arrival),
    /// so no extra delay is needed.
    func refocusTopmost(on display: DisplayInfo, excludingPid: pid_t) {
        // The CG→AX y-flip is computed against the *primary* display's frame —
        // passing the scanned display's frame skews every converted y on
        // systems where the flip is needed and the fallback isn't the primary.
        let primaryFrame = displayManager.currentDisplays().first?.frame ?? display.frame
        if let top = discovery.topmostRevealedWindow(on: display,
                                                     excludingWindowID: nil,
                                                     excludingPid: excludingPid,
                                                     primaryFrame: primaryFrame) {
            focusWindow(pid: top.pid, frameHint: top.frame)
        }
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return dx * dx + dy * dy
    }
}
