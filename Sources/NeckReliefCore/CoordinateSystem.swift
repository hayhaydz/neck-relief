import AppKit
import ApplicationServices
import CoreGraphics
import os

private let log = Logger(subsystem: "com.hayhaydz.neckrelief", category: "coordinates")

/// Converts CGWindowList bounds into AppKit global coordinates.
///
/// CGWindowList bounds are documented top-left-origin, but macOS 27 was
/// observed returning them already in AppKit (bottom-left) coordinates. The
/// running system's behavior is probed once by comparing live CG windows with
/// their AX counterparts, cached — and re-probed whenever the screen
/// configuration changes, because the probe compares against the primary
/// display's frame.
@MainActor
final class CoordinateSystem {

    /// `nil` = not yet probed.
    private var needsFlip: Bool?
    private var screenChangeObserver: NSObjectProtocol?

    init() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                log.notice("screen configuration changed — CG↔AX flip will be re-probed")
                self?.needsFlip = nil
            }
        }
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Converts a CGWindowList bounds rect into AppKit global coordinates.
    /// `primaryFrame` is the current primary display's full frame.
    func appKitRect(fromCG bounds: CGRect, primaryFrame: CGRect) -> CGRect {
        let flip = needsFlip ?? probe(primaryFrame: primaryFrame)
        needsFlip = flip
        return flip ? Geometry.appKitRect(fromCG: bounds, primaryFrame: primaryFrame) : bounds
    }

    /// Human-readable probe state for the diagnostics dump.
    var probeStateDescription: String {
        switch needsFlip {
        case .none: return "not probed yet"
        case .some(true): return "flipped (top-left origin)"
        case .some(false): return "identity (already AppKit)"
        }
    }

    /// Decides whether CG bounds need the y-flip by comparing a few live CG
    /// windows against their AX counterparts (matched by pid + size + x).
    /// Inconclusive → no flip (current macOS behavior).
    private func probe(primaryFrame: CGRect) -> Bool {
        let apps = AppInfoCache()
        var probed = 0
        for entry in CGWindowList.onScreen().layerZero.fromRegularApps(apps).contentSized {
            guard probed < 3 else { break }
            probed += 1
            for frame in axFrames(pid: entry.ownerPID)
            where abs(frame.width - entry.bounds.width) < 5
                && abs(frame.height - entry.bounds.height) < 5
                && abs(frame.minX - entry.bounds.minX) < 5 {
                if abs(frame.minY - entry.bounds.minY) < 10 {
                    log.notice("CG probe: CG already matches AX (no flip)")
                    return false
                }
                let flippedY = primaryFrame.maxY - entry.bounds.maxY
                if abs(frame.minY - flippedY) < 10 {
                    log.notice("CG probe: CG is top-left origin (flip needed)")
                    return true
                }
            }
        }
        log.notice("CG probe inconclusive — assuming no flip")
        return false
    }

    /// Frame-only AX window list (no CG id resolution — safe to call while probing).
    private func axFrames(pid: pid_t) -> [CGRect] {
        AXHelpers.windowElements(of: AXUIElementCreateApplication(pid))
            .compactMap { AXHelpers.frame(of: $0) }
    }
}
