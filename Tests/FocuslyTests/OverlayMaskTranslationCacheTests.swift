import AppKit
import XCTest
@testable import Focusly

final class OverlayMaskTranslationCacheTests: XCTestCase {
    /// Rejects cache reuse when only the overlay origin has shifted.
    func testTranslationCacheRejectsWindowFrameOriginChanges() {
        let cachedWindowFrame = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let currentWindowFrame = NSRect(x: 96, y: 94, width: 1728, height: 1117)
        let cachedBounds = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let currentBounds = NSRect(x: 0, y: 0, width: 1728, height: 1117)

        let compatible = OverlayController.translationCacheInputIsCompatible(
            cachedWindowFrame: cachedWindowFrame,
            currentWindowFrame: currentWindowFrame,
            cachedContentBounds: cachedBounds,
            currentContentBounds: currentBounds,
            cachedBackingScale: 2,
            currentBackingScale: 2,
            tolerance: 0.25
        )

        XCTAssertFalse(compatible)
    }

    /// Allows cache reuse when frame, bounds, and scale all remain stable.
    func testTranslationCacheAcceptsStableFrameBoundsAndScale() {
        let windowFrame = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let contentBounds = NSRect(x: 0, y: 0, width: 1728, height: 1117)

        let compatible = OverlayController.translationCacheInputIsCompatible(
            cachedWindowFrame: windowFrame,
            currentWindowFrame: windowFrame,
            cachedContentBounds: contentBounds,
            currentContentBounds: contentBounds,
            cachedBackingScale: 2,
            currentBackingScale: 2,
            tolerance: 0.25
        )

        XCTAssertTrue(compatible)
    }

    /// Rejects cache reuse when backing scale changes between samples.
    func testTranslationCacheRejectsBackingScaleChanges() {
        let windowFrame = NSRect(x: 0, y: 0, width: 1728, height: 1117)
        let contentBounds = NSRect(x: 0, y: 0, width: 1728, height: 1117)

        let compatible = OverlayController.translationCacheInputIsCompatible(
            cachedWindowFrame: windowFrame,
            currentWindowFrame: windowFrame,
            cachedContentBounds: contentBounds,
            currentContentBounds: contentBounds,
            cachedBackingScale: 2,
            currentBackingScale: 1,
            tolerance: 0.25
        )

        XCTAssertFalse(compatible)
    }
}
