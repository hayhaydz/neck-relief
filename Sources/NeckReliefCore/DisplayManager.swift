import AppKit

/// Direction of a hotkey press. With exactly two displays both directions resolve to
/// "the other display"; with more, it picks the nearest display on that side.
enum Direction {
    case left
    case right
}

/// Snapshot of one connected display. All coordinates are in AppKit global points
/// (origin at bottom-left of the primary display).
public struct DisplayInfo: Equatable {
    public let frame: CGRect          // full frame
    public let visibleFrame: CGRect   // excludes menu bar / notch
    public let displayID: CGDirectDisplayID
    public let isPrimary: Bool
    public let name: String

    public init(frame: CGRect,
                visibleFrame: CGRect,
                displayID: CGDirectDisplayID,
                isPrimary: Bool,
                name: String) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.displayID = displayID
        self.isPrimary = isPrimary
        self.name = name
    }
}

/// Pure geometry helpers. No AppKit dependencies at call time — everything takes rects,
/// so all of this is unit-testable.
public enum Geometry {

    /// Converts a rect from CGWindowList coordinates (origin at top-left of the primary
    /// display, y grows downward) to AppKit global coordinates.
    public static func appKitRect(fromCG cgRect: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(
            x: cgRect.minX,
            y: primaryFrame.maxY - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    /// Scales a size down proportionally (floor-rounded) so it fits inside `maxSize`.
    /// Returns the original size unchanged when it already fits.
    public static func scaledToFit(_ size: CGSize, maxSize: CGSize) -> CGSize {
        guard size.width > maxSize.width || size.height > maxSize.height else { return size }
        let scale = min(maxSize.width / size.width, maxSize.height / size.height)
        return CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
    }

    /// Shifts `frame` (whose size is assumed to fit) the minimal distance so it lies
    /// entirely inside `bounds`.
    public static func clamped(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        var origin = frame.origin
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - frame.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - frame.height)
        return CGRect(origin: origin, size: frame.size)
    }

    /// Placement rule (revised 2026-10-02, round 3):
    /// - size preserved exactly (proportional downscale only if it can't fit)
    /// - the window keeps the same offset from the target display's origin as it
    ///   had from the source's: same position, other monitor — every time,
    ///   regardless of where the mouse sits (cursor-relative rules made landings
    ///   inconsistent between presses and were removed)
    /// - always clamped fully inside the target's visible frame
    public static func targetFrame(window: CGRect,
                                    source: DisplayInfo,
                                    target: DisplayInfo) -> CGRect {
        let size = scaledToFit(window.size,
                               maxSize: CGSize(width: target.visibleFrame.width,
                                               height: target.visibleFrame.height))
        let offset = CGPoint(x: window.minX - source.frame.minX,
                             y: window.minY - source.frame.minY)
        let origin = CGPoint(x: target.frame.minX + offset.x,
                             y: target.frame.minY + offset.y)
        return clamped(CGRect(origin: origin, size: size), to: target.visibleFrame)
    }

    /// Smoothstep easing: symmetric ease-in-out with exact 0→0 and 1→1 endpoints.
    /// Input is clamped to 0…1.
    public static func smoothstep(_ t: CGFloat) -> CGFloat {
        let c = min(max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }

    /// Linear interpolation between two rects at fraction `t`. `t` is not clamped
    /// (callers pass eased values in 0…1).
    public static func interpolate(from a: CGRect, to b: CGRect, t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t,
               y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t,
               height: a.height + (b.height - a.height) * t)
    }

    /// Distance metric between two non-overlapping (or overlapping) rects — used to pick
    /// the nearest adjacent display.
    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
        let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        return dx + dy
    }
}

/// Wraps NSScreen and provides display lookup/placement inputs.
final class DisplayManager {

    /// Current displays, primary first (NSScreen order guarantees this).
    func currentDisplays() -> [DisplayInfo] {
        NSScreen.screens.enumerated().map { index, screen -> DisplayInfo in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value ?? CGDirectDisplayID(index)
            return DisplayInfo(
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                displayID: id,
                isPrimary: index == 0,
                name: screen.localizedName
            )
        }
    }

    /// Exact containment first; a point in the gap between displays (mid-flight
    /// frames, bezel dead zone) resolves to the nearest display instead of nil.
    func display(containing point: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        if let hit = displays.first(where: { $0.frame.contains(point) }) {
            return hit
        }
        let dot = CGRect(origin: point, size: .zero)
        return displays.min {
            Geometry.gap(dot, $0.frame) < Geometry.gap(dot, $1.frame)
        }
    }

    /// The display to hand a window to, given the source display and a direction.
    /// Prefers displays strictly on that side of the source; falls back to any other
    /// display, nearest by frame gap. Returns nil for single-display setups.
    func otherDisplay(than source: DisplayInfo,
                      in displays: [DisplayInfo],
                      direction: Direction) -> DisplayInfo? {
        let candidates = displays.filter { $0.displayID != source.displayID }
        guard !candidates.isEmpty else { return nil }

        let directional = candidates.filter { candidate in
            switch direction {
            case .left:  return candidate.frame.maxX <= source.frame.minX + 1
            case .right: return candidate.frame.minX >= source.frame.maxX - 1
            }
        }
        let pool = directional.isEmpty ? candidates : directional
        return pool.min { Geometry.gap($0.frame, source.frame) < Geometry.gap($1.frame, source.frame) }
    }
}
