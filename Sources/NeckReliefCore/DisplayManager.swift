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

    /// Placement rule (revised 2026-10-02, round 2):
    /// - size preserved exactly (proportional downscale only if it can't fit)
    /// - cursor on the target display → the window hangs from the cursor (top edge at
    ///   it, horizontally centered) when it fits below; otherwise it centers on the
    ///   cursor — so it never gets shoved far away by edge clamping
    /// - otherwise (cursor shares the window's display) → the window keeps the same
    ///   offset from the target display's origin as it had from the source's:
    ///   same position, other monitor
    /// - always clamped fully inside the target's visible frame
    public static func targetFrame(window: CGRect,
                                   source: DisplayInfo,
                                   target: DisplayInfo,
                                   mouse: CGPoint) -> CGRect {
        let size = scaledToFit(window.size,
                               maxSize: CGSize(width: target.visibleFrame.width,
                                               height: target.visibleFrame.height))
        let offset = CGPoint(x: window.minX - source.frame.minX,
                             y: window.minY - source.frame.minY)

        let origin: CGPoint
        if target.frame.contains(mouse) {
            let hangsFromCursor = mouse.y - size.height >= target.visibleFrame.minY
            let y = hangsFromCursor ? mouse.y - size.height : mouse.y - size.height / 2
            origin = CGPoint(x: mouse.x - size.width / 2, y: y)
        } else {
            origin = CGPoint(x: target.frame.minX + offset.x,
                             y: target.frame.minY + offset.y)
        }
        return clamped(CGRect(origin: origin, size: size), to: target.visibleFrame)
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

    func display(containing point: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
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
