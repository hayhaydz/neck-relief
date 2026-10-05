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
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let owner = entry[kCGWindowOwnerPID as String] as? Int32 else { continue }
            guard owner != getpid() else { continue }
            guard NSRunningApplication(processIdentifier: owner)?.activationPolicy == .regular else { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            guard abs(bounds.width - display.frame.width) < 2,
                  abs(bounds.height - display.frame.height) < 2,
                  abs(bounds.minX - display.frame.minX) < 2 else { continue }
            if axConfirmsFullscreen(pid: owner) {
                log.notice("display \(display.name, privacy: .public) has a fullscreen Space (pid \(owner, privacy: .public))")
                return true
            }
        }
        return false
    }

    /// Passive post-move sanity check: if a window we expected to be visible
    /// isn't (fullscreen-Space detection missed), say so via the menu bar
    /// instead of fighting the Space. The user reaches it with ⌃→ manually.
    static func hintIfHidden(windowID: CGWindowID, onFail: @escaping (String) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if !windowIsOnScreen(windowID) {
                onFail("⚠︎ Behind a fullscreen Space — press ⌃→")
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

    /// AX confirmation that `pid` owns a window reporting kAXFullscreenAttribute
    /// == true. When the app's window list can't be read at all, the CG
    /// full-frame signal is trusted on its own.
    private static func axConfirmsFullscreen(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windowsValue = windowsRef else {
            log.notice("AX unreachable for pid \(pid, privacy: .public) — trusting CG full-frame signal")
            return true
        }
        let elements = (unsafeBitCast(windowsValue, to: NSArray.self) as? [AXUIElement]) ?? []
        for element in elements {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, AXFullscreenAttribute, &ref) == .success,
               let value = ref,
               unsafeBitCast(value, to: CFBoolean.self) == kCFBooleanTrue {
                return true
            }
        }
        return false
    }
}
