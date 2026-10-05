import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.hayhaydz.neckrelief", category: "discovery")

/// Finds windows: the focused one, the remembered away window on its home
/// display, the window an arrival will cover, and CG ids for AX windows.
/// All AX/CG reads funnel through here so the identity rules (Electron helper
/// pids, missing CG ids) live in one place.
@MainActor
final class WindowDiscovery {

    private let displayManager: DisplayManager
    private let coordinates: CoordinateSystem

    init(displayManager: DisplayManager, coordinates: CoordinateSystem) {
        self.displayManager = displayManager
        self.coordinates = coordinates
    }

    // MARK: - Focused window

    /// Resolves the frontmost window through a fallback chain, because Electron apps
    /// (Slack!) can front a helper process whose AX element exposes no focused or
    /// main window:
    ///   1. systemWide kAXFocusedApplication → pid
    ///      cross-checked against NSWorkspace.frontmostApplication (knows the real
    ///      app); on mismatch the workspace pid wins
    ///   2. app element → kAXFocusedWindow → kAXMainWindow
    ///   3. first non-minimized window of the app's kAXWindows list
    /// Every failure logs distinctly so the next dump says exactly which step died.
    func focusedWindow() -> AXWindow? {
        let systemWide = AXUIElementCreateSystemWide()

        var appElement: AXUIElement?
        var appRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide,
                                          kAXFocusedApplicationAttribute as CFString,
                                          &appRef) == .success,
           let appValue = appRef {
            appElement = AXHelpers.element(appValue)
        } else {
            log.notice("AX: systemWide focusedApplication read failed")
        }

        var pid: pid_t = 0
        if let element = appElement {
            AXUIElementGetPid(element, &pid)
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            if front.processIdentifier != pid {
                log.notice("AX: focused app mismatch — AX pid \(pid), workspace pid \(front.processIdentifier) (\(front.localizedName ?? "?", privacy: .public)); using workspace")
                pid = front.processIdentifier
                appElement = AXUIElementCreateApplication(pid)
            }
        } else {
            log.notice("AX: NSWorkspace has no frontmostApplication")
        }
        guard pid != 0, let appElement = appElement else {
            log.notice("AX: no focused app resolvable")
            return nil
        }

        var winElement: AXUIElement?
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, attribute as CFString, &winRef) == .success,
               let winValue = winRef,
               let element = AXHelpers.element(winValue) {
                winElement = element
                break
            }
        }
        if winElement == nil {
            log.notice("AX: \(Format.appName(pid), privacy: .public) exposes no focused/main window — falling back to window list")
            winElement = windows(of: pid).first(where: { !$0.isMinimized })?.element
        }
        guard let winElement = winElement else {
            log.notice("AX: no usable window for \(Format.appName(pid), privacy: .public)")
            return nil
        }

        // A window whose frame can't be read would silently get a .zero frame and
        // derail the toggle.
        guard let frame = AXHelpers.frame(of: winElement) else {
            log.notice("AX: focused window of \(Format.appName(pid), privacy: .public) exposes no frame — bailing")
            return nil
        }
        let cgID = cgWindowID(pid: pid, frame: frame, primaryFrame: primaryFrame())
        return AXWindow(element: winElement,
                        pid: pid,
                        frame: frame,
                        cgWindowID: cgID,
                        isMinimized: AXHelpers.bool(of: winElement, kAXMinimizedAttribute as CFString))
    }

    // MARK: - Window lists

    /// All AX windows of an app, with CG ids resolved from a single list fetch —
    /// resolving ids one window at a time re-scanned the list per window.
    func windows(of pid: pid_t) -> [AXWindow] {
        let appElement = AXUIElementCreateApplication(pid)
        let primaryFrame = self.primaryFrame()
        let cgList = CGWindowList.onScreen().layerZero
        let apps = AppInfoCache()
        return AXHelpers.windowElements(of: appElement).compactMap { element in
            guard let frame = AXHelpers.frame(of: element) else { return nil }
            return AXWindow(element: element,
                            pid: pid,
                            frame: frame,
                            cgWindowID: cgWindowID(pid: pid, frame: frame, in: cgList, apps: apps, primaryFrame: primaryFrame),
                            isMinimized: AXHelpers.bool(of: element, kAXMinimizedAttribute as CFString))
        }
    }

    /// Finds the remembered window on its home display. Liveness is AX-based (CG pid
    /// matching is unreliable for Electron apps like Slack, whose AX pid can differ
    /// from the window-server's owner pid).
    func findHomeWindow(_ mem: WindowMemory, displays: [DisplayInfo]) -> (AXWindow, DisplayInfo)? {
        guard let display = displays.first(where: { $0.displayID == mem.originDisplayID }) else {
            log.notice("origin display \(mem.originDisplayID) no longer exists")
            return nil
        }
        let candidates = windows(of: mem.pid).filter { !$0.isMinimized }
        if candidates.isEmpty {
            log.notice("no AX windows for \(Format.appName(mem.pid), privacy: .public) — app likely quit")
            return nil
        }
        for candidate in candidates {
            let mid = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
            if display.frame.contains(mid) {
                log.info("found away window: \(Format.appName(mem.pid), privacy: .public) frame=\(Format.rect(candidate.frame), privacy: .public)")
                return (candidate, display)
            }
        }
        log.notice("\(Format.appName(mem.pid), privacy: .public) has \(candidates.count) window(s), none on origin display:")
        for c in candidates {
            log.info("  candidate frame=\(Format.rect(c.frame), privacy: .public) minimized=\(c.isMinimized)")
        }
        return nil
    }

    /// Front-to-back scan for the window the arriving window will cover. Filters out
    /// system processes, non-regular apps (panels, our own menu-bar app), and tiny
    /// windows — the old raw topmost pick kept grabbing the wrong thing.
    func topmostRevealedWindow(on display: DisplayInfo,
                               excludingWindowID: CGWindowID?,
                               excludingPid: pid_t,
                               primaryFrame: CGRect) -> RevealedWindow? {
        let apps = AppInfoCache()
        for entry in CGWindowList.onScreen().layerZero {
            if entry.ownerPID == excludingPid { continue }
            if let id = entry.id, id == excludingWindowID { continue }

            // Only real, user-facing apps.
            guard apps.isRegularApp(entry.ownerPID) else { continue }

            // Skip stray floating mini-windows…
            guard entry.bounds.width >= Tuning.minContentWidth && entry.bounds.height >= Tuning.minContentHeight else { continue }
            // …and screen-spanning windows like Finder's desktop (0,0 5120x1440).
            guard entry.bounds.width <= display.frame.width + 1,
                  entry.bounds.height <= display.frame.height + 1 else { continue }

            let frame = cgToAX(entry.bounds, primaryFrame: primaryFrame)
            if display.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                return RevealedWindow(pid: entry.ownerPID, frame: frame)
            }
        }
        return nil
    }

    // MARK: - Identity

    /// Loose window match: same pid is required (the caller checks); the CG id,
    /// when both sides have one, must agree. When either side lacks an id
    /// (common with Electron) the frame decides instead of matching any window
    /// of the app: size must match the remembered window, and when it sits on
    /// the origin display its position must be near the remembered spot — so a
    /// *different* window of the same app isn't conflated with the away window.
    func sameWindow(_ w: AXWindow, _ mem: WindowMemory) -> Bool {
        if let id = w.cgWindowID, let memID = mem.cgWindowID {
            return id == memID
        }
        guard abs(w.frame.width - mem.originFrame.width) < 2,
              abs(w.frame.height - mem.originFrame.height) < 2 else { return false }
        let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
        guard let origin = displayManager.currentDisplays()
            .first(where: { $0.displayID == mem.originDisplayID }) else { return true }
        guard origin.frame.contains(center) else { return true }
        return abs(w.frame.minX - mem.originFrame.minX) < 40
            && abs(w.frame.minY - mem.originFrame.minY) < 40
    }

    /// Same app even when Electron fronts multiple processes: compare bundle ids.
    func sameApp(_ a: pid_t, _ b: pid_t) -> Bool {
        guard a != b else { return true }
        guard let appA = NSRunningApplication(processIdentifier: a),
              let bundle = appA.bundleIdentifier,
              let appB = NSRunningApplication(processIdentifier: b) else { return false }
        return appB.bundleIdentifier == bundle
    }

    // MARK: - CG id resolution

    /// Finds the CGWindowID for an AX window. Electron helper processes can own the
    /// CG window under a different pid than AX reports, so pids sharing a bundle id
    /// with `pid` are accepted too.
    func cgWindowID(pid: pid_t, frame: CGRect, primaryFrame: CGRect) -> CGWindowID? {
        cgWindowID(pid: pid, frame: frame,
                   in: CGWindowList.onScreen().layerZero,
                   apps: AppInfoCache(),
                   primaryFrame: primaryFrame)
    }

    private func cgWindowID(pid: pid_t,
                            frame: CGRect,
                            in cgList: [CGWindowEntry],
                            apps: AppInfoCache,
                            primaryFrame: CGRect) -> CGWindowID? {
        let bundleID = apps.bundleID(pid)
        for entry in cgList {
            let sameOwner = entry.ownerPID == pid
                || (bundleID != nil && apps.bundleID(entry.ownerPID) == bundleID)
            guard sameOwner else { continue }
            let candidate = cgToAX(entry.bounds, primaryFrame: primaryFrame)
            if abs(candidate.midX - frame.midX) < Tuning.cgMatchTolerance && abs(candidate.midY - frame.midY) < Tuning.cgMatchTolerance {
                return entry.id
            }
        }
        return nil
    }

    // MARK: - Coordinates

    private func cgToAX(_ bounds: CGRect, primaryFrame: CGRect) -> CGRect {
        coordinates.appKitRect(fromCG: bounds, primaryFrame: primaryFrame)
    }

    private func primaryFrame() -> CGRect {
        displayManager.currentDisplays().first?.frame ?? .zero
    }
}
