import XCTest
import CoreGraphics
@testable import NeckReliefCore

// Fixtures mirror PlacementTests: primary on the right, secondary on the left.
private let primary = DisplayInfo(
    frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
    visibleFrame: CGRect(x: 0, y: 25, width: 2560, height: 1415),
    displayID: 1,
    isPrimary: true,
    name: "Studio")

private let secondary = DisplayInfo(
    frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
    displayID: 2,
    isPrimary: false,
    name: "Dell")

private let farRight = DisplayInfo(
    frame: CGRect(x: 2660, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 2660, y: 0, width: 1920, height: 1080),
    displayID: 3,
    isPrimary: false,
    name: "Right")

private let farLeft = DisplayInfo(
    frame: CGRect(x: -4280, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: -4280, y: 0, width: 1920, height: 1080),
    displayID: 4,
    isPrimary: false,
    name: "FarLeft")

private let below = DisplayInfo(
    frame: CGRect(x: 0, y: -1100, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 0, y: -1100, width: 1920, height: 1080),
    displayID: 5,
    isPrimary: false,
    name: "Below")

@MainActor
final class DisplaySelectionTests: XCTestCase {

    private let manager = DisplayManager()

    // MARK: - Geometry.gap

    func testGapIsZeroForOverlappingRects() {
        let a = CGRect(x: 0, y: 0, width: 500, height: 500)
        let b = CGRect(x: 250, y: 250, width: 500, height: 500)
        XCTAssertEqual(Geometry.gap(a, b), 0)
    }

    func testGapMeasuresHorizontalDistance() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 150, y: 0, width: 100, height: 100)
        XCTAssertEqual(Geometry.gap(a, b), 50)
    }

    func testGapSumsBothAxesForDiagonalSeparation() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 150, y: 150, width: 100, height: 100)
        XCTAssertEqual(Geometry.gap(a, b), 100)
    }

    // MARK: - DisplayManager.otherDisplay

    func testTwoDisplaysResolveLeftAndRight() {
        let displays = [primary, secondary]
        XCTAssertEqual(manager.otherDisplay(than: secondary, in: displays, direction: .right), primary)
        XCTAssertEqual(manager.otherDisplay(than: primary, in: displays, direction: .left), secondary)
    }

    func testTwoDisplaysFallBackAcrossDirection() {
        // Nothing is right of the primary in a two-display setup — the only
        // other display is still the answer.
        let displays = [primary, secondary]
        XCTAssertEqual(manager.otherDisplay(than: primary, in: displays, direction: .right), secondary)
    }

    func testSingleDisplayReturnsNil() {
        XCTAssertNil(manager.otherDisplay(than: primary, in: [primary], direction: .right))
        XCTAssertNil(manager.otherDisplay(than: primary, in: [primary], direction: .left))
    }

    func testPicksNearestDisplayOnTheRequestedSide() {
        let displays = [primary, secondary, farLeft]
        // Both left of the primary; the adjacent one wins.
        XCTAssertEqual(manager.otherDisplay(than: primary, in: displays, direction: .left), secondary)
        // From the far left, both others are to the right; the nearest wins.
        XCTAssertEqual(manager.otherDisplay(than: farLeft, in: displays, direction: .right), secondary)
        // The far-right display is only reachable via an explicit right press.
        XCTAssertEqual(manager.otherDisplay(than: primary, in: [primary, secondary, farRight], direction: .right), farRight)
    }

    func testVerticallyStackedFallsBackAcrossDirection() {
        // Nothing is horizontally right of the bottom display — the stacked
        // display above it is still the answer.
        let displays = [primary, below]
        XCTAssertEqual(manager.otherDisplay(than: below, in: displays, direction: .right), primary)
    }

    // MARK: - DisplayManager.display(containing:)

    func testContainmentResolvesExactDisplay() {
        let displays = [primary, secondary]
        XCTAssertEqual(manager.display(containing: CGPoint(x: 100, y: 720), in: displays), primary)
        XCTAssertEqual(manager.display(containing: CGPoint(x: -1800, y: 540), in: displays), secondary)
    }

    func testPointInDeadZoneResolvesNearestDisplay() {
        // Secondary ends at x = -80, primary starts at 0: a bezel gap.
        let gappy = DisplayInfo(frame: CGRect(x: -2000, y: 0, width: 1920, height: 1080),
                                visibleFrame: CGRect(x: -2000, y: 0, width: 1920, height: 1080),
                                displayID: 6, isPrimary: false, name: "Gappy")
        let displays = [primary, gappy]
        // -60 sits 20pt from gappy, 60pt from the primary.
        XCTAssertEqual(manager.display(containing: CGPoint(x: -60, y: 540), in: displays), gappy)
        XCTAssertEqual(manager.display(containing: CGPoint(x: -20, y: 540), in: displays), primary)
    }

    // MARK: - Geometry.clamped edges

    func testClampedMovesInsideOnBothAxes() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        XCTAssertEqual(Geometry.clamped(CGRect(x: -50, y: -50, width: 100, height: 100), to: bounds),
                       CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(Geometry.clamped(CGRect(x: 980, y: 980, width: 100, height: 100), to: bounds),
                       CGRect(x: 900, y: 900, width: 100, height: 100))
    }

    func testClampedOversizedWindowPinsToRightEdge() {
        // A window wider than the bounds can't fit; it right-aligns against
        // the far edge and overflows to the left (targetFrame's scaledToFit
        // prevents this combination in practice).
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let result = Geometry.clamped(CGRect(x: 0, y: 0, width: 1200, height: 500), to: bounds)
        XCTAssertEqual(result.maxX, bounds.maxX)
        XCTAssertEqual(result.minX, bounds.maxX - 1200)
    }

    // MARK: - Geometry.scaledToFit edges

    func testScaledToFitScalesByHeightWhenHeightConstrains() {
        let result = Geometry.scaledToFit(CGSize(width: 1000, height: 1200),
                                          maxSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(result, CGSize(width: 900, height: 1080))
    }

    func testScaledToFitKeepsDegenerateSizes() {
        XCTAssertEqual(Geometry.scaledToFit(.zero, maxSize: CGSize(width: 1920, height: 1080)), .zero)
    }
}
