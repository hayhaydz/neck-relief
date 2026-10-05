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

/// An AX window with the bits the toggle needs. `cgWindowID` is nil when the
/// window couldn't be matched in the CG list (common with Electron helpers).
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
///   window on the away display and press (new intent) or reset from the menu.
///
/// Fullscreen never gets fought for: a fullscreen landing display gets a *background
/// move* (window parks on its desktop Space, focus untouched), and a fullscreen
/// window exits fullscreen before moving.
@MainActor
final class WindowManager {

    var onFeedback: ((String) -> Void)?

    private let displayManager = DisplayManager()
    private let coordinates = CoordinateSystem()
    private lazy var discovery = WindowDiscovery(displayManager: displayManager, coordinates: coordinates)
    private lazy var focusController = FocusController(discovery: discovery, displayManager: displayManager)
    private let mover = WindowMover()
    private var memory: WindowMemory?

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

        guard let focused = discovery.focusedWindow() else {
            log.notice("no focused window — nothing to do")
            onFeedback?("⚠︎ No focused window")
            return
        }
        guard !focused.isMinimized else {
            log.notice("focused window \(Format.appName(focused.pid), privacy: .public) is minimized")
            onFeedback?("⚠︎ Window is minimized")
            return
        }
        log.notice("press: focused=\(Format.appName(focused.pid), privacy: .public) pid=\(focused.pid) frame=\(Format.rect(focused.frame), privacy: .public) cg=\(focused.cgWindowID.map(String.init) ?? "nil", privacy: .public)")

        let center = CGPoint(x: focused.frame.midX, y: focused.frame.midY)
        let source = displayManager.display(containing: center, in: displays) ?? displays[0]
        log.notice("source display: \(source.name, privacy: .public) id=\(source.displayID)")

        // 1) The focused window IS the away window.
        if let mem = memory, discovery.sameApp(focused.pid, mem.pid), discovery.sameWindow(focused, mem) {
            if source.displayID == mem.originDisplayID {
                log.notice("state: away window focused at home → bringing over")
                bringOver(away: focused, from: source.displayID, direction: direction)
            } else {
                log.notice("state: away window focused here → sending home")
                sendHome(mem, away: focused, fallbackDisplayID: source.displayID)
            }
            return
        }

        // 2) Focused elsewhere: chain-flip the away window back if it exists.
        if let mem = memory, source.displayID != mem.originDisplayID {
            if let (away, originDisplay) = discovery.findHomeWindow(mem, displays: displays) {
                log.notice("state: chain-flip → bringing \(Format.appName(mem.pid), privacy: .public) over while \(Format.appName(focused.pid), privacy: .public) keeps focus intent")
                bringOver(away: away, from: originDisplay.displayID, direction: direction)
                return
            }
            log.notice("away window not found on origin display — dropping memory")
            memory = nil
        } else if memory != nil {
            log.notice("state: new intent on away display → replacing away window")
        }

        // 3) No (or dead) memory: outbound the focused window.
        bringOver(away: focused, from: source.displayID, direction: direction)
    }

    /// Moves `away` from its home display to the other one, records/refreshes the
    /// memory (including a fresh capture of the window it will cover), and focuses
    /// it on arrival. A fullscreen window exits fullscreen first.
    private func bringOver(away: AXWindow, from sourceDisplayID: CGDirectDisplayID, direction: Direction) {
        withoutFullscreen(away) { [weak self] refreshed in
            guard let self = self else { return }
            // Re-snapshot: the fullscreen-exit wait can span a display change.
            let displays = self.displayManager.currentDisplays()
            guard displays.count >= 2 else {
                self.onFeedback?("⚠︎ Needs two displays")
                return
            }
            let center = CGPoint(x: refreshed.frame.midX, y: refreshed.frame.midY)
            guard let source = displays.first(where: { $0.displayID == sourceDisplayID })
                    ?? self.displayManager.display(containing: center, in: displays) else { return }
            self.performBringOver(away: refreshed, from: source, displays: displays, direction: direction)
        }
    }

    /// Returns the away window to its recorded home frame. The memory deliberately
    /// STAYS so the next press can flip it back — that's what makes it chainable.
    private func sendHome(_ mem: WindowMemory, away: AXWindow, fallbackDisplayID: CGDirectDisplayID) {
        withoutFullscreen(away) { [weak self] refreshed in
            guard let self = self else { return }
            let displays = self.displayManager.currentDisplays()
            guard !displays.isEmpty else { return }
            let center = CGPoint(x: refreshed.frame.midX, y: refreshed.frame.midY)
            let fallback = displays.first(where: { $0.displayID == fallbackDisplayID })
                ?? self.displayManager.display(containing: center, in: displays)
            guard let fallback = fallback else { return }
            self.performSendHome(mem, away: refreshed, displays: displays, fallbackDisplay: fallback)
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
        log.notice("window of \(Format.appName(window.pid), privacy: .public) is fullscreen — exiting it first")
        AXHelpers.setBool(false, on: window.element, attribute: AXFullscreenAttribute)
        awaitFullscreenExitAndSettle(window.element, previousFrame: nil, deadline: .now() + 1.5) { [weak self] settled in
            guard let self = self else { return }
            guard !AXHelpers.bool(of: window.element, AXFullscreenAttribute),
                  let frame = AXHelpers.frame(of: window.element) else {
                self.onFeedback?("⚠︎ \(Format.appName(window.pid)) won't exit fullscreen")
                return
            }
            if !settled {
                log.notice("fullscreen exit didn't settle in time — moving anyway")
            }
            let primaryFrame = self.displayManager.currentDisplays().first?.frame ?? .zero
            let refreshed = AXWindow(element: window.element,
                                     pid: window.pid,
                                     frame: frame,
                                     cgWindowID: self.discovery.cgWindowID(pid: window.pid, frame: frame, primaryFrame: primaryFrame),
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
        let revealed = background ? nil : discovery.topmostRevealedWindow(on: target,
                                                                          excludingWindowID: away.cgWindowID,
                                                                          excludingPid: away.pid,
                                                                          primaryFrame: displays[0].frame)
        if background {
            log.notice("target \(target.name, privacy: .public) has a fullscreen Space → background move")
        } else if revealed == nil {
            log.notice("reveal capture: nothing suitable found on \(target.name, privacy: .public)")
        } else if let r = revealed {
            log.notice("reveal capture: \(Format.appName(r.pid), privacy: .public) frame=\(Format.rect(r.frame), privacy: .public)")
        }

        let newFrame = Geometry.targetFrame(window: away.frame, source: source, target: target)
        log.notice("placement: \(Format.rect(away.frame), privacy: .public) → \(Format.rect(newFrame), privacy: .public) on \(target.name, privacy: .public)")

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
                self.onFeedback?("⚠︎ \(Format.appName(pid)) resisted the move")
            }
            if background {
                self.onFeedback?("⇄ behind fullscreen — ⌃→ to reach it")
            } else {
                self.focusController.focus(element, pid: pid)
                if let windowID = windowID {
                    FullscreenGuard.hintIfHidden(windowID: windowID) { [weak self] message in
                        self?.onFeedback?(message)
                    }
                }
            }
        }
    }

    private func performSendHome(_ mem: WindowMemory, away: AXWindow, displays: [DisplayInfo], fallbackDisplay: DisplayInfo) {
        // If the origin display went away while the window was out, park the
        // window fully inside the display we're staying on instead of moving
        // it to coordinates that no longer exist.
        let destination: CGRect
        if displays.contains(where: { $0.displayID == mem.originDisplayID }) {
            destination = mem.originFrame
        } else {
            log.notice("origin display gone — parking on \(fallbackDisplay.name, privacy: .public) instead")
            let size = Geometry.scaledToFit(mem.originFrame.size, maxSize: fallbackDisplay.visibleFrame.size)
            destination = Geometry.clamped(CGRect(origin: mem.originFrame.origin, size: size),
                                           to: fallbackDisplay.visibleFrame)
        }
        let element = away.element
        mover.move(element: element, pid: mem.pid, from: away.frame, to: destination) { [weak self] success in
            guard let self = self else { return }
            log.notice("sent \(Format.appName(mem.pid), privacy: .public) home to \(Format.rect(destination), privacy: .public) settled=\(success, privacy: .public)")
            if !success {
                self.onFeedback?("⚠︎ \(Format.appName(mem.pid)) resisted the move")
            }
            if mem.arrivedInBackground {
                // Focus was never taken from the user on arrival — leave it alone.
                log.notice("refocus: none — arrival was a background move")
                return
            }
            if let revealed = mem.revealed {
                log.notice("refocus: revealed \(Format.appName(revealed.pid), privacy: .public) frame=\(Format.rect(revealed.frame), privacy: .public)")
                self.focusController.focusWindow(pid: revealed.pid, frameHint: revealed.frame)
            } else {
                log.notice("refocus: no captured reveal — falling back to topmost on \(fallbackDisplay.name, privacy: .public)")
                self.focusController.refocusTopmost(on: fallbackDisplay, excludingPid: mem.pid)
            }
        }
    }

    func resetState() {
        memory = nil
        log.notice("state reset by user")
    }

    // MARK: - Diagnostics

    /// Human-readable dump of everything the toggle sees. Copied to the clipboard by
    /// the menu item; the fastest way to answer "why wasn't window X detected".
    func diagnosticsDump() -> String {
        Diagnostics(displayManager: displayManager,
                    coordinates: coordinates,
                    discovery: discovery).dump(memory: memory)
    }
}
