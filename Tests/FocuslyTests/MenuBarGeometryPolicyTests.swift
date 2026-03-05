import AppKit
import XCTest
@testable import Focusly

@MainActor
final class MenuBarGeometryPolicyTests: XCTestCase {
    /// Verifies the main overlay trims only the menu bar strip, not Dock-occupied edges.
    func testMainOverlayExcludesOnlyTopMenuBarBandWhenMenuBarExcluded() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        // Dock occupies left and bottom; menu bar remains anchored at the top.
        let visibleFrame = NSRect(x: 96, y: 80, width: 1632, height: 999)

        let resolved = OverlayWindow.resolvedMainOverlayFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            menuBarExcluded: true,
            backingScale: 2
        )

        XCTAssertEqual(resolved.origin.x, screenFrame.origin.x)
        XCTAssertEqual(resolved.origin.y, screenFrame.origin.y)
        XCTAssertEqual(resolved.width, screenFrame.width)
        XCTAssertGreaterThan(resolved.height, visibleFrame.height)
        XCTAssertLessThan(resolved.height, screenFrame.height)
    }

    func testMainOverlayUsesScreenFrameWhenMenuBarIncluded() {
        let screenFrame = NSRect(x: 1440, y: 0, width: 2560, height: 1440)
        let visibleFrame = NSRect(x: 1440, y: 0, width: 2560, height: 1398)

        let resolved = OverlayWindow.resolvedMainOverlayFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            menuBarExcluded: false,
            backingScale: 1
        )

        XCTAssertEqual(resolved, screenFrame)
    }

    func testMenuBarBackdropStaysPinnedToTopWithSubpointSeamOverlap() {
        let screenFrame = NSRect(x: 1440, y: 0, width: 2560, height: 1440)
        let visibleFrame = NSRect(x: 1440, y: 0, width: 2560, height: 1398)

        let frame = MenuBarBackdropWindow.menuBarFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            backingScale: 2
        )

        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.maxY, screenFrame.maxY)
        XCTAssertEqual(frame?.origin.x, screenFrame.origin.x)
        XCTAssertEqual(frame?.width, screenFrame.width)
        XCTAssertLessThan(frame?.origin.y ?? 0, visibleFrame.maxY)
        XCTAssertGreaterThan(frame?.origin.y ?? 0, visibleFrame.maxY - 1.5)
    }

    func testMenuBarBackdropHandlesSecondaryDisplayCoordinates() {
        let screenFrame = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let visibleFrame = NSRect(x: -1920, y: 0, width: 1920, height: 1056)

        let frame = MenuBarBackdropWindow.menuBarFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            backingScale: 1
        )

        XCTAssertEqual(frame?.origin.x, -1920)
        XCTAssertEqual(frame?.width, 1920)
        XCTAssertEqual(frame?.maxY, 1080)
        XCTAssertLessThan(frame?.origin.y ?? 0, 1056)
        XCTAssertGreaterThan(frame?.origin.y ?? 0, 1054.5)
    }
}
