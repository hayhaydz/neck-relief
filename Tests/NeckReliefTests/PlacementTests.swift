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

    func testMouseOnTargetHangsWindowFromCursor() {
        let window = CGRect(x: -1500, y: 200, width: 800, height: 600) // on secondary
        let mouse = CGPoint(x: 640, y: 720)                            // on primary
        let result = Geometry.targetFrame(window: window, source: secondary, target: primary, mouse: mouse)

        XCTAssertEqual(result.size, window.size)
        XCTAssertEqual(result.midX, mouse.x)   // horizontally centered on cursor
        XCTAssertEqual(result.maxY, mouse.y)   // top edge at the cursor
    }

    func testMouseLowOnTargetCentersInsteadOfClampingAway() {
        // Cursor near the bottom: an 800x600 window cannot hang from it, so it
        // centers on the cursor (then clamps to the visible frame).
        let window = CGRect(x: -1500, y: 200, width: 800, height: 600)
        let mouse = CGPoint(x: 640, y: 200)
        let result = Geometry.targetFrame(window: window, source: secondary, target: primary, mouse: mouse)

        XCTAssertEqual(result.size, window.size)
        XCTAssertEqual(result.midX, mouse.x)
        XCTAssertEqual(result.minY, primary.visibleFrame.minY) // centered (-100) clamped up
    }

    func testMouseOnSourceKeepsSameOffset() {
        let window = CGRect(x: -1920 + 100, y: 0 + 150, width: 800, height: 600)
        let mouse = CGPoint(x: -1000, y: 500) // still on secondary
        let result = Geometry.targetFrame(window: window, source: secondary, target: primary, mouse: mouse)

        XCTAssertEqual(result.size, window.size)
        // Same position, other monitor: offset from the display origin is preserved.
        XCTAssertEqual(result.minX, primary.frame.minX + 100)
        XCTAssertEqual(result.minY, primary.frame.minY + 150)
    }

    func testPlacementClampedToVisibleFrame() {
        let window = CGRect(x: -1000, y: 200, width: 800, height: 1200) // taller than fits comfortably
        let mouse = CGPoint(x: 300, y: 30)                              // near bottom of primary
        let result = Geometry.targetFrame(window: window, source: secondary, target: primary, mouse: mouse)

        XCTAssertGreaterThanOrEqual(result.minY, primary.visibleFrame.minY)
        XCTAssertLessThanOrEqual(result.maxY, primary.visibleFrame.maxY)
        XCTAssertGreaterThanOrEqual(result.minX, primary.visibleFrame.minX)
        XCTAssertLessThanOrEqual(result.maxX, primary.visibleFrame.maxX)
    }

    func testOversizedWindowScalesProportionally() {
        let window = CGRect(x: -1500, y: 0, width: 2200, height: 1000)
        let mouse = CGPoint(x: 1280, y: 720)
        let result = Geometry.targetFrame(window: window, source: secondary, target: primary, mouse: mouse)

        XCTAssertLessThanOrEqual(result.width, primary.visibleFrame.width)
        XCTAssertLessThanOrEqual(result.height, primary.visibleFrame.height)
        let originalRatio = window.height / window.width
        let resultRatio = result.height / result.width
        XCTAssertEqual(abs(resultRatio - originalRatio), 0, accuracy: 0.01)
    }

    func testFittingWindowKeepsExactSize() {
        let window = CGRect(x: -1500, y: 100, width: 1000, height: 700)
        let mouse = CGPoint(x: 1280, y: 720)
        let result = Geometry.targetFrame(window: window, source: secondary, target: primary, mouse: mouse)

        XCTAssertEqual(result.size, CGSize(width: 1000, height: 700))
    }

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
