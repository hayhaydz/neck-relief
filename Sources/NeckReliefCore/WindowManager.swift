import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.hayhaydz.neckrelief", category: "toggle")

/// Snapshot of the window that got covered when the away-window arrived — restored
/// to focus when the away-window goes home.
struct RevealedWindow {
    let pid: pid_t
    let frame: CGRect
}

/// The sticky toggle state: one window is "away" at a time, and the state survives
/// both directions of the flip so the hotkey can be chained indefinitely.
///
/// `arrivedInBackground` records that the away window was parked behind a
/// fullscreen Space on arrival (no focus was taken from the user) — sending it
/// home then must not "restore" focus anywhere either.
struct WindowMemory {
    let pid: pid_t
    let cgWindowID: CGWindowID?
    let originFrame: CGRect
    let originDisplayID: CGDirectDisplayID
    let revealed: RevealedWindow?
    let arrivedInBackground: Bool
}

struct AXWindow {
    let element: AXUIElement
    let pid: pid_t
    let frame: CGRect
    let cgWindowID: CGWindowID?
    let isMinimized: Bool
}

/// One core verb: a sticky two-state flip.
///
/// - Press with the away-window focused: it comes to you (same position, other
///   monitor) and takes keyboard focus on arrival.
/// - Press again — from anywhere: it returns to its exact spot and focus lands on the
///   window it had covered.
/// - Press yet again: it comes back. The state persists until you focus a *different*
/// window on the away display and press (new intent) or reset from the menu.
///
/// Fullscreen never gets fought for: a fullscreen landing display gets a *background
/// move* (window parks on its desktop Space, focus untouched), and a fullscreen
/// window exits fullscreen before moving.
@MainActor
final class WindowManager {

    var onFeedback: ((String) -> Void)?

    private let displayManager = DisplayManager()
    private let coordinates = CoordinateSystem()
    private let mover = WindowMover()
    private var memory: WindowMemory?

    /// Converts a CGWindowList bounds rect into AppKit global coordinates.
    private func cgToAX(_ bounds: CGRect, primaryFrame: CGRect) -> CGRect {
        coordinates.appKitRect(fromCG: bounds, primaryFrame: primaryFrame)
    }

    // MARK: - Toggle

    func toggle(direction: Direction) {
        guard Permissions.isTrusted else {
            onFeedback?("⚠︎ Grant Accessibility — see ⇄ menu")
            return
        }

        let displays = displayManager.currentDisplays()
        guard displays.count >= 2 else {
            onFeedback?("⚠︎ Needs two displays")
            return
        }
        let primaryFrame = displays[0].frame

        guard let focused = focusedAXWindow(primaryFrame: primaryFrame) else {
            log.notice("no focused window — nothing to do")
            onFeedback?("⚠︎ No focused window")
            return
        }
        guard !focused.isMinimized else {
            log.notice("focused window \(self.appName(focused.pid), privacy: .public) is minimized")
            onFeedback?("⚠︎ Window is minimized")
            return
        }
        log.notice("press: focused=\(self.appName(focused.pid), privacy: .public) pid=\(focused.pid) frame=\(self.rect(focused.frame), privacy: .public) cg=\(focused.cgWindowID.map(String.init) ?? "nil", privacy: .public)")

        let center = CGPoint(x: focused.frame.midX, y: focused.frame.midY)
        let source = displayManager.display(containing: center, in: displays) ?? displays[0]
        log.notice("source display: \(source.name, privacy: .public) id=\(source.displayID)")

        // 1) The focused window IS the away window.
        if let mem = memory, sameApp(focused.pid, mem.pid), sameWindow(focused, mem) {
            if source.displayID == mem.originDisplayID {
                log.notice("state: away window focused at home → bringing over")
                bringOver(away: focused, from: source, displays: displays, direction: direction)
            } else {
                log.notice("state: away window focused here → sending home")
                sendHome(mem, away: focused, fallbackDisplay: source)
            }
            return
        }

        // 2) Focused elsewhere: chain-flip the away window back if it exists.
        if let mem = memory, source.displayID != mem.originDisplayID {
            if let (away, originDisplay) = findHomeWindow(mem, displays: displays) {
                log.notice("state: chain-flip → bringing \(self.appName(mem.pid), privacy: .public) over while \(self.appName(focused.pid), privacy: .public) keeps focus intent")
                bringOver(away: away, from: originDisplay, displays: displays, direction: direction)
                return
            }
            log.notice("away window not found on origin display — dropping memory")
            memory = nil
        } else if memory != nil {
            log.notice("state: new intent on away display → replacing away window")
        }

        // 3) No (or dead) memory: outbound the focused window.
        bringOver(away: focused, from: source, displays: displays, direction: direction)
    }

    /// Moves `away` from its home display to the other one, records/refreshes the
    /// memory (including a fresh capture of the window it will cover), and focuses
    /// it on arrival. A fullscreen window exits fullscreen first.
    private func bringOver(away: AXWindow, from source: DisplayInfo, displays: [DisplayInfo], direction: Direction) {
        withoutFullscreen(away) { [weak self] refreshed in
            self?.performBringOver(away: refreshed, from: source, displays: displays, direction: direction)
        }
    }

    /// Returns the away window to its recorded home frame. The memory deliberately
    /// STAYS so the next press can flip it back — that's what makes it chainable.
    private func sendHome(_ mem: WindowMemory, away: AXWindow, fallbackDisplay: DisplayInfo) {
        withoutFullscreen(away) { [weak self] refreshed in
            self?.performSendHome(mem, away: refreshed, fallbackDisplay: fallbackDisplay)
        }
    }

    /// Runs `action` once the window is no longer native-fullscreen. macOS fights
    /// AX moves on fullscreen windows, so a fullscreen window (focused, or the
    /// remembered away window the user fullscreened meanwhile) is taken out of
    /// fullscreen first; its post-exit frame becomes the window's real frame.
    private func withoutFullscreen(_ window: AXWindow, then action: @escaping (AXWindow) -> Void) {
        guard AXHelpers.bool(of: window.element, AXFullscreenAttribute) else {
            action(window)
            return
        }
        log.notice("window of \(self.appName(window.pid), privacy: .public) is fullscreen — exiting it first")
        AXHelpers.setBool(false, on: window.element, attribute: AXFullscreenAttribute)
        awaitFullscreenExitAndSettle(window.element, previousFrame: nil, deadline: .now() + 1.5) { [weak self] settled in
            guard let self = self else { return }
            guard !AXHelpers.bool(of: window.element, AXFullscreenAttribute),
                  let frame = AXHelpers.frame(of: window.element) else {
                self.onFeedback?("⚠︎ \(self.appName(window.pid)) won't exit fullscreen")
                return
            }
            if !settled {
                log.notice("fullscreen exit didn't settle in time — moving anyway")
            }
            let primaryFrame = self.displayManager.currentDisplays().first?.frame ?? .zero
            let refreshed = AXWindow(element: window.element,
                                     pid: window.pid,
                                     frame: frame,
                                     cgWindowID: self.cgWindowID(pid: window.pid, frame: frame, primaryFrame: primaryFrame),
                                     isMinimized: false)
            action(refreshed)
        }
    }

    /// Polls (~100 ms ticks) until the window is out of native fullscreen AND its
    /// frame has held still for two consecutive reads (the exit animation runs
    /// ~0.5 s). `completion(false)` on deadline; the caller decides how to degrade.
    private func awaitFullscreenExitAndSettle(_ element: AXUIElement,
                                              previousFrame: CGRect?,
                                              deadline: DispatchTime,
                                              completion: @escaping (Bool) -> Void) {
        if DispatchTime.now() > deadline {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            let fullscreen = AXHelpers.bool(of: element, AXFullscreenAttribute)
            guard !fullscreen, let frame = AXHelpers.frame(of: element) else {
                self.awaitFullscreenExitAndSettle(element, previousFrame: nil, deadline: deadline, completion: completion)
                return
            }
            if let previous = previousFrame,
               abs(frame.minX - previous.minX) < 2, abs(frame.minY - previous.minY) < 2,
               abs(frame.width - previous.width) < 2, abs(frame.height - previous.height) < 2 {
                completion(true)
            } else {
                self.awaitFullscreenExitAndSettle(element, previousFrame: frame, deadline: deadline, completion: completion)
            }
        }
    }

    private func performBringOver(away: AXWindow, from source: DisplayInfo, displays: [DisplayInfo], direction: Direction) {
        guard let target = displayManager.otherDisplay(than: source, in: displays, direction: direction) else {
            log.notice("no other display found")
            onFeedback?("⚠︎ No display that way")
            return
        }

        // Background move: the target's active Space is fullscreen — park the
        // window on that display's desktop Space, take no focus, touch no Space.
        let background = FullscreenGuard.spaceHasFullscreenWindow(on: target)
        let revealed = background ? nil : topmostRevealedWindow(on: target,
                                                                excludingWindowID: away.cgWindowID,
                                                                excludingPid: away.pid,
                                                                primaryFrame: displays[0].frame)
        if background {
            log.notice("target \(target.name, privacy: .public) has a fullscreen Space → background move")
        } else if revealed == nil {
            log.notice("reveal capture: nothing suitable found on \(target.name, privacy: .public)")
        } else if let r = revealed {
            log.notice("reveal capture: \(self.appName(r.pid), privacy: .public) frame=\(self.rect(r.frame), privacy: .public)")
        }

        let newFrame = Geometry.targetFrame(window: away.frame, source: source, target: target)
        log.notice("placement: \(self.rect(away.frame), privacy: .public) → \(self.rect(newFrame), privacy: .public) on \(target.name, privacy: .public)")

        memory = WindowMemory(pid: away.pid,
                              cgWindowID: away.cgWindowID,
                              originFrame: away.frame,
                              originDisplayID: source.displayID,
                              revealed: revealed,
                              arrivedInBackground: background)

        let element = away.element
        let pid = away.pid
        let windowID = away.cgWindowID
        mover.move(element: element, pid: pid, from: away.frame, to: newFrame) { [weak self] success in
            guard let self = self else { return }
            if !success {
                self.onFeedback?("⚠︎ \(self.appName(pid)) resisted the move")
            }
            if background {
                self.onFeedback?("⇄ behind fullscreen — ⌃→ to reach it")
            } else {
                self.focusElement(element, pid: pid)
                if let windowID = windowID {
                    FullscreenGuard.hintIfHidden(windowID: windowID) { [weak self] message in
                        self?.onFeedback?(message)
                    }
                }
            }
        }
    }

    private func performSendHome(_ mem: WindowMemory, away: AXWindow, fallbackDisplay: DisplayInfo) {
        let element = away.element
        mover.move(element: element, pid: mem.pid, from: away.frame, to: mem.originFrame) { [weak self] success in
            guard let self = self else { return }
            log.notice("sent \(self.appName(mem.pid), privacy: .public) home to \(self.rect(mem.originFrame), privacy: .public) settled=\(success, privacy: .public)")
            if !success {
                self.onFeedback?("⚠︎ \(self.appName(mem.pid)) resisted the move")
            }
            if mem.arrivedInBackground {
                // Focus was never taken from the user on arrival — leave it alone.
                log.notice("refocus: none — arrival was a background move")
                return
            }
            if let revealed = mem.revealed {
                log.notice("refocus: revealed \(self.appName(revealed.pid), privacy: .public) frame=\(self.rect(revealed.frame), privacy: .public)")
                self.focusWindow(pid: revealed.pid, frameHint: revealed.frame)
            } else {
                log.notice("refocus: no captured reveal — falling back to topmost on \(fallbackDisplay.name, privacy: .public)")
                self.refocusTopmostWindow(on: fallbackDisplay, excludingPid: mem.pid)
            }
        }
    }

    func resetState() {
        memory = nil
        log.notice("state reset by user")
    }

    // MARK: - Window discovery

    /// Resolves the frontmost window through a fallback chain, because Electron apps
    /// (Slack!) can front a helper process whose AX element exposes no focused or
    /// main window:
    ///   1. systemWide kAXFocusedApplication → pid
    ///      cross-checked against NSWorkspace.frontmostApplication (knows the real
    ///      app); on mismatch the workspace pid wins
    ///   2. app element → kAXFocusedWindow → kAXMainWindow
    ///   3. first non-minimized window of the app's kAXWindows list
    /// Every failure logs distinctly so the next dump says exactly which step died.
    private func focusedAXWindow(primaryFrame: CGRect) -> AXWindow? {
        let systemWide = AXUIElementCreateSystemWide()

        var appElement: AXUIElement?
        var appRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide,
                                          kAXFocusedApplicationAttribute as CFString,
                                          &appRef) == .success,
           let appValue = appRef {
            appElement = unsafeBitCast(appValue, to: AXUIElement.self)
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
               let winValue = winRef {
                winElement = unsafeBitCast(winValue, to: AXUIElement.self)
                break
            }
        }
        if winElement == nil {
            log.notice("AX: \(self.appName(pid), privacy: .public) exposes no focused/main window — falling back to window list")
            winElement = axWindows(pid: pid).first(where: { !$0.isMinimized })?.element
        }
        guard let winElement = winElement else {
            log.notice("AX: no usable window for \(self.appName(pid), privacy: .public)")
            return nil
        }

        // A window whose frame can't be read would silently get a .zero frame and
        // derail the toggle.
        guard let frame = AXHelpers.frame(of: winElement) else {
            log.notice("AX: focused window of \(self.appName(pid), privacy: .public) exposes no frame — bailing")
            return nil
        }
        let cgID = cgWindowID(pid: pid, frame: frame, primaryFrame: primaryFrame)
        return AXWindow(element: winElement,
                        pid: pid,
                        frame: frame,
                        cgWindowID: cgID,
                        isMinimized: AXHelpers.bool(of: winElement, kAXMinimizedAttribute as CFString))
    }

    /// Finds the remembered window on its home display. Liveness is AX-based (CG pid
    /// matching is unreliable for Electron apps like Slack, whose AX pid can differ
    /// from the window-server's owner pid).
    private func findHomeWindow(_ mem: WindowMemory, displays: [DisplayInfo]) -> (AXWindow, DisplayInfo)? {
        guard let display = displays.first(where: { $0.displayID == mem.originDisplayID }) else {
            log.notice("origin display \(mem.originDisplayID) no longer exists")
            return nil
        }
        let candidates = axWindows(pid: mem.pid).filter { !$0.isMinimized }
        if candidates.isEmpty {
            log.notice("no AX windows for \(self.appName(mem.pid), privacy: .public) — app likely quit")
            return nil
        }
        for candidate in candidates {
            let mid = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
            if display.frame.contains(mid) {
                log.notice("found away window: \(self.appName(mem.pid), privacy: .public) frame=\(self.rect(candidate.frame), privacy: .public)")
                return (candidate, display)
            }
        }
        log.notice("\(self.appName(mem.pid), privacy: .public) has \(candidates.count) window(s), none on origin display:")
        for c in candidates {
            log.notice("  candidate frame=\(self.rect(c.frame), privacy: .public) minimized=\(c.isMinimized)")
        }
        return nil
    }

    private func axWindows(pid: pid_t) -> [AXWindow] {
        let appElement = AXUIElementCreateApplication(pid)
        let primaryFrame = displayManager.currentDisplays().first?.frame ?? .zero
        // One CG fetch for the whole window list — resolving ids one window at
        // a time re-scanned the list per window.
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

    /// Front-to-back scan for the window the arriving window will cover. Filters out
    /// system processes, non-regular apps (panels, our own menu-bar app), and tiny
    /// windows — the old raw topmost pick kept grabbing the wrong thing.
    private func topmostRevealedWindow(on display: DisplayInfo,
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
            guard entry.bounds.width >= 300 && entry.bounds.height >= 200 else { continue }
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

    // MARK: - Identity helpers

    /// Loose window match: same pid is required (the caller checks); the CG id,
    /// when both sides have one, must agree. When either side lacks an id
    /// (common with Electron) the frame decides instead of matching any window
    /// of the app: size must match the remembered window, and when it sits on
    /// the origin display its position must be near the remembered spot — so a
    /// *different* window of the same app isn't conflated with the away window.
    private func sameWindow(_ w: AXWindow, _ mem: WindowMemory) -> Bool {
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
    private func sameApp(_ a: pid_t, _ b: pid_t) -> Bool {
        guard a != b else { return true }
        guard let appA = NSRunningApplication(processIdentifier: a),
              let bundle = appA.bundleIdentifier,
              let appB = NSRunningApplication(processIdentifier: b) else { return false }
        return appB.bundleIdentifier == bundle
    }

    /// Finds the CGWindowID for an AX window. Electron helper processes can own the
    /// CG window under a different pid than AX reports, so pids sharing a bundle id
    /// with `pid` are accepted too.
    private func cgWindowID(pid: pid_t, frame: CGRect, primaryFrame: CGRect) -> CGWindowID? {
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
            if abs(candidate.midX - frame.midX) < 50 && abs(candidate.midY - frame.midY) < 50 {
                return entry.id
            }
        }
        return nil
    }

    // MARK: - AX reads

    // MARK: - AX writes are owned by WindowMover (glide + verified landing)

    // MARK: - Focus (AX-based: NSRunningApplication.activate() alone no-ops from a
    // background app on macOS 14+)

    private func focusElement(_ element: AXUIElement, pid: pid_t) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, element)
        NSRunningApplication(processIdentifier: pid)?.activate()
        log.notice("focus → \(self.appName(pid), privacy: .public)")
    }

    /// Focus a window of `pid` nearest `frameHint` (the captured "revealed" window).
    private func focusWindow(pid: pid_t, frameHint: CGRect?) {
        let candidates = axWindows(pid: pid).filter { !$0.isMinimized }
        let target = candidates.min(by: { a, b in
            distance(a.frame, frameHint ?? .zero) < distance(b.frame, frameHint ?? .zero)
        })
        if let target = target {
            focusElement(target.element, pid: pid)
            return
        }
        log.notice("focus fallback: no AX windows for \(self.appName(pid), privacy: .public), activating app")
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return dx * dx + dy * dy
    }

    /// Last-resort refocus when nothing was captured: frontmost suitable window on
    /// the display the user is staying on. Called at move completion (arrival),
    /// so no extra delay is needed.
    private func refocusTopmostWindow(on display: DisplayInfo, excludingPid: pid_t) {
        // The CG→AX y-flip is computed against the *primary* display's frame —
        // passing the scanned display's frame skews every converted y on
        // systems where the flip is needed and the fallback isn't the primary.
        let primaryFrame = displayManager.currentDisplays().first?.frame ?? display.frame
        if let top = topmostRevealedWindow(on: display,
                                           excludingWindowID: nil,
                                           excludingPid: excludingPid,
                                           primaryFrame: primaryFrame) {
            focusWindow(pid: top.pid, frameHint: top.frame)
        }
    }

    // MARK: - Diagnostics

    private func appName(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid:\(pid)"
    }

    private func rect(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }

    /// Human-readable dump of everything the toggle sees. Copied to the clipboard by
    /// the menu item; the fastest way to answer "why wasn't window X detected".
    func diagnosticsDump() -> String {
        var lines: [String] = []
        lines.append("== Neck Relief diagnostics — \(Date()) ==")
        lines.append("CG→AX coordinates: \(coordinates.probeStateDescription)")

        let displays = displayManager.currentDisplays()
        lines.append("Displays (\(displays.count)):")
        for d in displays {
            let fullscreen = FullscreenGuard.spaceHasFullscreenWindow(on: d) ? " [fullscreen Space]" : ""
            lines.append("  \(d.isPrimary ? "primary" : "secondary"): \(d.name) id=\(d.displayID) frame=\(self.rect(d.frame)) visible=\(self.rect(d.visibleFrame))\(fullscreen)")
        }

        if let mem = memory {
            lines.append("Memory: away=\(self.appName(mem.pid)) pid=\(mem.pid) cg=\(mem.cgWindowID.map(String.init) ?? "nil")")
            lines.append("  origin=\(self.rect(mem.originFrame)) onDisplay=\(mem.originDisplayID) arrivedInBackground=\(mem.arrivedInBackground)")
            if let r = mem.revealed {
                lines.append("  revealed=\(self.appName(r.pid)) pid=\(r.pid) frame=\(self.rect(r.frame))")
            } else {
                lines.append("  revealed=nil")
            }
        } else {
            lines.append("Memory: none")
        }

        if let focused = focusedAXWindow(primaryFrame: displays.first?.frame ?? .zero) {
            lines.append("Focused (AX): \(self.appName(focused.pid)) pid=\(focused.pid) frame=\(self.rect(focused.frame)) cg=\(focused.cgWindowID.map(String.init) ?? "nil") minimized=\(focused.isMinimized)")
        } else {
            lines.append("Focused (AX): none")
        }

        lines.append("CG windows (on-screen, layer 0, ≥300x200, regular apps):")
        let primaryFrame = displays.first?.frame ?? .zero
        let apps = AppInfoCache()
        for entry in CGWindowList.onScreen().layerZero.fromRegularApps(apps).contentSized {
            let id = entry.id.map(String.init) ?? "?"
            let frame = cgToAX(entry.bounds, primaryFrame: primaryFrame)
            lines.append("  cg=\(id) \(apps.name(entry.ownerPID)) pid=\(entry.ownerPID) frame=\(self.rect(frame))")
        }

        lines.append("AX windows per app:")
        var seen = Set<pid_t>()
        for entry in CGWindowList.onScreen().layerZero.fromRegularApps(apps) {
            guard !seen.contains(entry.ownerPID) else { continue }
            seen.insert(entry.ownerPID)
            let windows = axWindows(pid: entry.ownerPID)
            guard !windows.isEmpty else { continue }
            lines.append("  \(apps.name(entry.ownerPID)) pid=\(entry.ownerPID):")
            for w in windows {
                lines.append("    frame=\(self.rect(w.frame)) minimized=\(w.isMinimized) cg=\(w.cgWindowID.map(String.init) ?? "nil")")
            }
        }
        return lines.joined(separator: "\n")
    }
}
