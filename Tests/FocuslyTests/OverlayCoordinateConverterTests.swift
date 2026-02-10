import XCTest
@testable import Focusly

final class OverlayCoordinateConverterTests: XCTestCase {
    func testGlobalToOverlayContentConversionIsPixelAlignedOnMixedScale() {
        let overlayFrame = NSRect(x: 1920, y: 0, width: 2560, height: 1440)
        let contentBounds = NSRect(x: 0, y: 0, width: 2560, height: 1440)
        let globalRect = NSRect(x: 2050.3, y: 100.2, width: 500.4, height: 300.6)

        let converted = OverlayCoordinateConverter.globalRectToOverlayContent(
            globalRect,
            overlayFrame: overlayFrame,
            contentBounds: contentBounds,
            backingScale: 2
        )

        XCTAssertNotNil(converted)
        guard let converted else { return }
        XCTAssertEqual((converted.minX * 2).rounded(), converted.minX * 2, accuracy: 0.0001)
        XCTAssertEqual((converted.minY * 2).rounded(), converted.minY * 2, accuracy: 0.0001)
        XCTAssertEqual((converted.maxX * 2).rounded(), converted.maxX * 2, accuracy: 0.0001)
        XCTAssertEqual((converted.maxY * 2).rounded(), converted.maxY * 2, accuracy: 0.0001)
    }

    func testIntersectingDisplaysPreservesHandoffWithoutGap() {
        let screens = [
            OverlayCoordinateConverter.ScreenDescriptor(
                displayID: 1,
                frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                backingScale: 2
            ),
            OverlayCoordinateConverter.ScreenDescriptor(
                displayID: 2,
                frame: NSRect(x: 1920, y: 0, width: 2560, height: 1440),
                backingScale: 1
            )
        ]

        let crossingRect = NSRect(x: 1890, y: 200, width: 480, height: 640)
        let resolved = OverlayCoordinateConverter.intersectingDisplays(
            for: crossingRect,
            screens: screens,
            previousDisplayIDs: [1],
            primaryThreshold: 0.12,
            handoffThreshold: 0.02
        )

        print("cross-screen handoff demo: from=[1] to=\(resolved.sorted()) stable=true")
        XCTAssertEqual(resolved, Set([1, 2]))
    }

    func testIntersectingDisplaysDropsOldDisplayAfterCrossingCompletes() {
        let screens = [
            OverlayCoordinateConverter.ScreenDescriptor(
                displayID: 1,
                frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                backingScale: 2
            ),
            OverlayCoordinateConverter.ScreenDescriptor(
                displayID: 2,
                frame: NSRect(x: 1920, y: 0, width: 2560, height: 1440),
                backingScale: 1
            )
        ]

        let movedRect = NSRect(x: 2300, y: 220, width: 700, height: 500)
        let resolved = OverlayCoordinateConverter.intersectingDisplays(
            for: movedRect,
            screens: screens,
            previousDisplayIDs: [1, 2],
            primaryThreshold: 0.12,
            handoffThreshold: 0.02
        )

        XCTAssertEqual(resolved, Set([2]))
    }
}
