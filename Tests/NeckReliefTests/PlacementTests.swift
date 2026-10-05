import XCTest
import CoreGraphics
@testable import NeckReliefCore

// Fixtures: primary Studio-style display on the right, secondary Dell-style on the left.
private let primary = DisplayInfo(
    frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
    visibleFrame: CGRect(x: 0, y: 25, width: 2560, height: 1415), // menu bar
    displayID: 1,
    isPrimary: true,
    name: "Studio")

private let secondary = DisplayInfo(
    frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
    displayID: 2,
    isPrimary: false,
    name: "Dell")

final class PlacementTests: XCTestCase {

    // MARK: - Same-offset placement (round 3)

    func testSameOffsetSecondaryToPrimary() {
        let window = CGRect(x: -1920 + 100, y: 0 + 150, width: 800, height: 600) // on secondary
        let result = Geometry.targetFrame(window: window, source: secondary, target: primary)

        XCTAssertEqual(result.size, window.size)
        // Same position, other monitor: offset from the display origin is preserved.
        XCTAssertEqual(result.minX, primary.frame.minX + 100)
        XCTAssertEqual(result.minY, primary.frame.minY + 150)
    }

    func testSameOffsetPrimaryToSecondary() {
        let window = CGRect(x: 0 + 100, y: 0 + 150, width: 800, height: 600) // on primary
        let result = Geometry.targetFrame(window: window, source: primary, target: secondary)

        XCTAssertEqual(result.size, window.size)
        XCTAssertEqual(result.minX, secondary.frame.minX + 100)
        XCTAssertEqual(result.minY, secondary.frame.minY + 150)
    }

    func testPlacementClampedBelowMenuBarOnTarget() {
        // Window in the top region of the secondary maps above the primary's
        // visible top (menu bar) → clamped down.
        let window = CGRect(x: -1920 + 100, y: 900, width: 800, height: 600) // maxY 1500 > 1440
        let result = Geometry.targetFrame(window: window, source: secondary, target: primary)

        XCTAssertEqual(result.maxY, primary.visibleFrame.maxY)
        XCTAssertEqual(result.minY, primary.visibleFrame.maxY - 600)
    }

    func testPlacementClampedToBottomEdgeOnTarget() {
        // Window hanging below the secondary's bottom maps below the primary's
        // visible bottom → clamped up.
        let window = CGRect(x: -1920 + 100, y: -80, width: 800, height: 600)
        let result = Geometry.targetFrame(window: window, source: secondary, target: primary)

        XCTAssertEqual(result.minY, primary.visibleFrame.minY)
    }

    func testOversizedWindowScalesProportionally() {
        // 2200x1000 can't fit the secondary's 1920-wide visible frame.
        let window = CGRect(x: 100, y: 200, width: 2200, height: 1000) // on primary
        let result = Geometry.targetFrame(window: window, source: primary, target: secondary)

        XCTAssertLessThanOrEqual(result.width, secondary.visibleFrame.width)
        XCTAssertLessThanOrEqual(result.height, secondary.visibleFrame.height)
        XCTAssertEqual(result.width, secondary.visibleFrame.width, accuracy: 1) // width was the constraint
        let originalRatio = window.height / window.width
        let resultRatio = result.height / result.width
        XCTAssertEqual(abs(resultRatio - originalRatio), 0, accuracy: 0.01)
    }

    func testFittingWindowKeepsExactSize() {
        let window = CGRect(x: -1500, y: 100, width: 1000, height: 700)
        let result = Geometry.targetFrame(window: window, source: secondary, target: primary)

        XCTAssertEqual(result.size, CGSize(width: 1000, height: 700))
    }

    // MARK: - Easing (WindowMover curve)

    func testSmoothstepEndpointsExact() {
        XCTAssertEqual(Geometry.smoothstep(0), 0)
        XCTAssertEqual(Geometry.smoothstep(1), 1)
        XCTAssertEqual(Geometry.smoothstep(0.5), 0.5, accuracy: 1e-12)
    }

    func testSmoothstepClampsOutOfRangeInput() {
        XCTAssertEqual(Geometry.smoothstep(-0.3), 0)
        XCTAssertEqual(Geometry.smoothstep(1.7), 1)
    }

    func testSmoothstepIsMonotonic() {
        var previous: CGFloat = -1
        for step in 0...20 {
            let t = CGFloat(step) / 20
            let value = Geometry.smoothstep(t)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testSmoothstepMidpointSymmetry() {
        // s(t) + s(1-t) == 1 → symmetric ease-in-out.
        XCTAssertEqual(Geometry.smoothstep(0.2) + Geometry.smoothstep(0.8), 1, accuracy: 1e-12)
        XCTAssertEqual(Geometry.smoothstep(0.35) + Geometry.smoothstep(0.65), 1, accuracy: 1e-12)
    }

    func testInterpolateHitsEndpointsExactly() {
        let a = CGRect(x: -1500, y: 100, width: 800, height: 600)
        let b = CGRect(x: 200, y: 300, width: 1000, height: 500)

        XCTAssertEqual(Geometry.interpolate(from: a, to: b, t: 0), a)
        XCTAssertEqual(Geometry.interpolate(from: a, to: b, t: 1), b)
    }

    func testInterpolateMidpoint() {
        let a = CGRect(x: 0, y: 0, width: 800, height: 600)
        let b = CGRect(x: 200, y: 300, width: 1000, height: 500)
        let mid = Geometry.interpolate(from: a, to: b, t: 0.5)

        XCTAssertEqual(mid.minX, 100)
        XCTAssertEqual(mid.minY, 150)
        XCTAssertEqual(mid.width, 900)
        XCTAssertEqual(mid.height, 550)
    }

    // MARK: - Coordinate + scaling helpers (unchanged)

    func testCGWindowFlip() {
        let primaryFrame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let cgRect = CGRect(x: 10, y: 20, width: 100, height: 50) // CG: y from top
        let flipped = Geometry.appKitRect(fromCG: cgRect, primaryFrame: primaryFrame)

        XCTAssertEqual(flipped.minX, 10)
        XCTAssertEqual(flipped.minY, 1440 - (20 + 50))
        XCTAssertEqual(flipped.width, 100)
        XCTAssertEqual(flipped.height, 50)
    }

    func testScaledToFitLeavesFittingSizesUntouched() {
        let size = CGSize(width: 800, height: 600)
        let result = Geometry.scaledToFit(size, maxSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(result, size)
    }

    func testScaledToFitLimitsByConstrainingDimension() {
        let size = CGSize(width: 2200, height: 1000)
        let result = Geometry.scaledToFit(size, maxSize: CGSize(width: 1920, height: 1080))
        XCTAssertLessThanOrEqual(result.width, 1920)
        XCTAssertLessThanOrEqual(result.height, 1000) // height was not the constraint
    }
}
