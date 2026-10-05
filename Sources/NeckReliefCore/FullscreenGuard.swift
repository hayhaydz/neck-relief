import AppKit
import ApplicationServices
import CoreGraphics
import os

private let log = Logger(subsystem: "com.hayhaydz.neckrelief", category: "fullscreen")

/// `kAXFullscreenAttribute` isn't exposed to Swift by the SDK — the raw AX
/// attribute string is "AXFullScreen" (same constant Rectangle & friends use).
let AXFullscreenAttribute: CFString = "AXFullScreen" as CFString

/// Passive fullscreen-Space awareness (round 3, 2026-10-02).
///
/// macOS never renders a normal window above a native-fullscreen Space, so a
/// window moved onto a display whose active Space is fullscreen lands on that
/// display's *desktop* Space, out of sight. Neck Relief now treats that as a
/// feature — the *background move*: the window is placed, the fullscreen Space
/// and the user's focus stay untouched, and the user reaches the window
/// manually later (⌃→ / exiting fullscreen).
///
/// The previous behavior — synthesizing ⌃-arrow key events to steal the Space
/// automatically — was removed: it fought the user for control of Spaces.
enum FullscreenGuard {

    /// True when the active Space on `display` looks native-fullscreen: a real
    /// app's layer-0 window covers the display's FULL frame. Sizes and minX are
    /// identical in both CG and AppKit coordinate systems, so no flip probing is
    /// needed here. (A maximized-but-windowed app sits inside `visibleFrame` —
    /// menu bar still visible — so full-frame coverage is the signal; a same-
    /// sized window on a vertically-stacked display is ruled out by requiring an
    /// AX fullscreen confirmation.)
    static func spaceHasFullscreenWindow(on display: DisplayInfo) -> Bool {
        let apps = AppInfoCache()
        for entry in CGWindowList.onScreen().layerZero.fromRegularApps(apps) {
            guard abs(entry.bounds.width - display.frame.width) < 2,
                  abs(entry.bounds.height - display.frame.height) < 2,
                  abs(entry.bounds.minX - display.frame.minX) < 2 else { continue }
            if axConfirmsFullscreen(pid: entry.ownerPID) {
                log.info("display \(display.name, privacy: .public) has a fullscreen Space (pid \(entry.ownerPID, privacy: .public))")
                return true
            }
        }
        return false
    }

    /// Passive post-move sanity check: if a window we expected to be visible
    /// isn't (fullscreen-Space detection missed), say so via the menu bar
    /// instead of fighting the Space. The user reaches it with ⌃→ manually.
    static func hintIfHidden(windowID: CGWindowID, onFail: @escaping (String) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.hiddenHintDelay) {
            if !windowIsOnScreen(windowID) {
                onFail("⚠︎ Behind a fullscreen Space — press ⌃→")
            }
        }
    }

    static func windowIsOnScreen(_ windowID: CGWindowID) -> Bool {
        CGWindowList.onScreen().contains { $0.id == windowID }
    }

    /// AX confirmation that `pid` owns a window reporting kAXFullscreenAttribute
    /// == true. When the app's window list can't be read at all, the CG
    /// full-frame signal is trusted on its own.
    private static func axConfirmsFullscreen(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        let elements = AXHelpers.windowElements(of: appElement)
        if elements.isEmpty {
            // Distinguish "no windows" from "AX unreadable" — only the latter
            // trusts the CG signal on its own.
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) != .success {
                log.notice("AX unreachable for pid \(pid, privacy: .public) — trusting CG full-frame signal")
                return true
            }
            return false
        }
        return elements.contains { AXHelpers.bool(of: $0, AXFullscreenAttribute) }
    }
}
