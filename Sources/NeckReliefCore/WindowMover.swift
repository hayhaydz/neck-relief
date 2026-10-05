import AppKit
import ApplicationServices
import os
import QuartzCore

private let log = Logger(subsystem: "com.hayhaydz.neckrelief", category: "mover")

/// Applies frames to other apps' windows with a short ease-in-out glide and a
/// *verified* landing (frame read back, re-asserted while the app drifts it).
/// Replaces the old blind set-and-hope: Electron apps in particular re-position
/// themselves shortly after an AX move.
///
/// At most one move runs at a time per instance; `move` cancels any in-flight
/// one, so rapid hotkey chaining simply animates from wherever the window
/// currently is. The completion fires exactly once on the main queue — unless
/// the move is cancelled by a successor, in which case it never fires (the
/// successor owns the window now).
@MainActor
final class WindowMover {

    struct Parameters {
        /// Glide duration; the move is a jump when Reduce Motion is on.
        var duration: TimeInterval = 0.2
        /// Timer tick rate for the glide.
        var stepInterval: TimeInterval = 1.0 / 60.0
        /// How far the applied frame may sit from the target and still count.
        var tolerance: CGFloat = 1.5
        /// Re-assert attempts when the app keeps drifting the window.
        var reassertAttempts = 3
        /// Delay before each verification read (gives the app time to settle).
        var verifyDelay: TimeInterval = 0.1
    }

    let parameters = Parameters()

    private var timer: Timer?
    private var pendingVerify: DispatchWorkItem?

    // MARK: - Public

    /// Moves the window from `start` to `destination`, gliding unless Reduce
    /// Motion is set or the frames already coincide. `completion(true)` when the
    /// final frame matches `destination` within tolerance; `completion(false)`
    /// when the app kept re-positioning it.
    func move(element: AXUIElement,
              pid: pid_t,
              from start: CGRect,
              to destination: CGRect,
              completion: @escaping (Bool) -> Void) {
        cancel()

        let finish = { [weak self] in
            self?.applyAndVerify(element: element,
                                 pid: pid,
                                 frame: destination,
                                 attempt: 0,
                                 completion: completion)
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || framesMatch(start, destination, tolerance: 0.5) {
            finish()
            return
        }

        log.info("glide: pid \(pid, privacy: .public) → (\(Int(destination.minX)),\(Int(destination.minY)) \(Int(destination.width))x\(Int(destination.height))) over \(self.parameters.duration, privacy: .public)s")
        let startTime = CACurrentMediaTime()
        let animatesSize = abs(start.width - destination.width) > 0.5
            || abs(start.height - destination.height) > 0.5

        let glide = Timer(timeInterval: parameters.stepInterval, repeats: true) { [weak self] timer in
            // Scheduled on the main run loop — the timer block itself is
            // nonisolated, so hop back explicitly.
            MainActor.assumeIsolated {
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                let elapsed = CACurrentMediaTime() - startTime
                if elapsed >= self.parameters.duration {
                    timer.invalidate()
                    if self.timer === timer { self.timer = nil }
                    // Exact endpoint — interpolation at t=1 can carry float fuzz.
                    AXHelpers.set(position: destination.origin, on: element)
                    if animatesSize { AXHelpers.set(size: destination.size, on: element) }
                    finish()
                    return
                }
                let eased = Geometry.smoothstep(CGFloat(elapsed / self.parameters.duration))
                let step = Geometry.interpolate(from: start, to: destination, t: eased)
                AXHelpers.set(position: step.origin, on: element)
                if animatesSize {
                    AXHelpers.set(size: step.size, on: element)
                }
            }
        }
        RunLoop.main.add(glide, forMode: .common)
        timer = glide
    }

    /// Cancels any in-flight move; its completion will never fire.
    func cancel() {
        timer?.invalidate()
        timer = nil
        pendingVerify?.cancel()
        pendingVerify = nil
    }

    // MARK: - Verified application

    /// Size first, position last (position is authoritative). The frame is then
    /// read back after a short settle delay; drift is re-asserted up to
    /// `reassertAttempts` times before giving up with `false`.
    private func applyAndVerify(element: AXUIElement,
                                pid: pid_t,
                                frame: CGRect,
                                attempt: Int,
                                completion: @escaping (Bool) -> Void) {
        AXHelpers.set(size: frame.size, on: element)
        AXHelpers.set(position: frame.origin, on: element)

        let verify = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingVerify = nil
            if self.frame(element, matches: frame) {
                log.info("move verified (attempt \(attempt, privacy: .public))")
                completion(true)
                return
            }
            guard attempt < self.parameters.reassertAttempts else {
                if let actual = AXHelpers.frame(of: element) {
                    log.error("move refused by pid \(pid, privacy: .public): actual (\(Int(actual.minX)),\(Int(actual.minY)) \(Int(actual.width))x\(Int(actual.height))) target (\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)))")
                } else {
                    log.error("move refused by pid \(pid, privacy: .public): frame unreadable")
                }
                completion(false)
                return
            }
            log.notice("move drifted (attempt \(attempt, privacy: .public)) — re-asserting")
            self.applyAndVerify(element: element, pid: pid, frame: frame, attempt: attempt + 1, completion: completion)
        }
        pendingVerify = verify
        DispatchQueue.main.asyncAfter(deadline: .now() + parameters.verifyDelay, execute: verify)
    }

    // MARK: - AX plumbing

    private func frame(_ element: AXUIElement, matches target: CGRect) -> Bool {
        guard let actual = AXHelpers.frame(of: element) else { return false }
        return framesMatch(actual, target, tolerance: parameters.tolerance)
    }

    private func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }
}
