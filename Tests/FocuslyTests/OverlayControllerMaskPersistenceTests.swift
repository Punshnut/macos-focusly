@testable import Focusly
import AppKit
import XCTest

@MainActor
final class OverlayControllerMaskPersistenceTests: XCTestCase {
    /// Ensures frozen mask regions survive supplemental mask merges.
    func testMergedMaskPreservesFrozenRegions() {
        let controller = OverlayController(activeWindowSnapshotResolver: { _, _ in nil })
        let frozenRegion = OverlayWindow.MaskRegion(
            rect: NSRect(x: 0, y: 0, width: 200, height: 200),
            cornerRadius: 12
        )
        let menuRegion = OverlayWindow.MaskRegion(
            rect: NSRect(x: 20, y: 160, width: 160, height: 40),
            cornerRadius: 4
        )

        let merged = controller.testingMergedMaskRegions(
            frozen: [frozenRegion],
            supplemental: [menuRegion]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains(frozenRegion))
        XCTAssertTrue(merged.contains(menuRegion))
    }

    /// Validates frozen regions are preferred over cached snapshots when available.
    func testLastKnownMaskPrefersFrozenRegions() {
        let controller = OverlayController(activeWindowSnapshotResolver: { _, _ in nil })
        let displayID: DisplayID = 42
        let frozen = [
            OverlayWindow.MaskRegion(rect: NSRect(x: 0, y: 0, width: 100, height: 100), cornerRadius: 6)
        ]
        let cached = [
            OverlayWindow.MaskRegion(rect: NSRect(x: 10, y: 10, width: 80, height: 80), cornerRadius: 4)
        ]

        let preferred = controller.testingLastKnownMaskRegions(
            for: displayID,
            frozenMask: frozen,
            cachedMask: cached
        )
        XCTAssertEqual(preferred, frozen)

        let fallback = controller.testingLastKnownMaskRegions(
            for: displayID,
            frozenMask: nil,
            cachedMask: cached
        )
        XCTAssertEqual(fallback, cached)
    }

    /// Falls back to the preferred cache entry when no active or cached mask exists.
    func testLastKnownMaskFallsBackToPreferredCacheEntry() {
        let controller = OverlayController(activeWindowSnapshotResolver: { _, _ in nil })
        let displayID: DisplayID = 7
        let preferredMask = [
            OverlayWindow.MaskRegion(
                rect: NSRect(x: 50, y: 50, width: 120, height: 120),
                cornerRadius: 10
            )
        ]

        let resolved = controller.testingLastKnownMaskRegions(
            for: displayID,
            frozenMask: nil,
            cachedMask: nil,
            preferredCacheMask: preferredMask
        )
        XCTAssertEqual(resolved, preferredMask)
    }

    /// Ignores empty cached masks and uses the next valid fallback entry.
    func testLastKnownMaskSkipsEmptyCachedEntry() {
        let controller = OverlayController(activeWindowSnapshotResolver: { _, _ in nil })
        let displayID: DisplayID = 9
        let fallbackMask = [
            OverlayWindow.MaskRegion(
                rect: NSRect(x: 15, y: 15, width: 90, height: 90),
                cornerRadius: 8
            )
        ]

        let resolved = controller.testingLastKnownMaskRegions(
            for: displayID,
            frozenMask: nil,
            cachedMask: [],
            preferredCacheMask: fallbackMask
        )
        XCTAssertEqual(resolved, fallbackMask)
    }
}
