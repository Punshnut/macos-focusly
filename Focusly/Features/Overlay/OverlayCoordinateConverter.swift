import AppKit

/// Pure coordinate conversion helpers used to keep overlay geometry stable across mixed-DPI displays.
enum OverlayCoordinateConverter {
    struct ScreenDescriptor: Equatable {
        let displayID: DisplayID
        let frame: NSRect
        let backingScale: CGFloat
    }

    /// Converts a global-space rect into overlay content coordinates, snapping to backing pixels.
    static func globalRectToOverlayContent(
        _ globalRect: NSRect,
        overlayFrame: NSRect,
        contentBounds: NSRect,
        backingScale: CGFloat
    ) -> NSRect? {
        let intersection = globalRect.intersection(overlayFrame)
        guard !intersection.isNull else { return nil }
        var rect = NSRect(
            x: intersection.origin.x - overlayFrame.origin.x,
            y: intersection.origin.y - overlayFrame.origin.y,
            width: intersection.width,
            height: intersection.height
        )
        rect = rect.intersection(contentBounds)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        return alignRectToBackingGrid(rect, scale: backingScale)
    }

    /// Returns the overlap ratio between a global window frame and one screen.
    static func intersectionRatio(globalRect: NSRect, screenFrame: NSRect) -> CGFloat {
        let intersection = globalRect.intersection(screenFrame)
        guard !intersection.isNull else { return 0 }
        let area = max(globalRect.width * globalRect.height, .ulpOfOne)
        return (intersection.width * intersection.height) / area
    }

    /// Determines which screens should actively track this window, preserving previous owners with hysteresis.
    static func intersectingDisplays(
        for globalRect: NSRect,
        screens: [ScreenDescriptor],
        previousDisplayIDs: Set<DisplayID>,
        primaryThreshold: CGFloat = 0.12,
        handoffThreshold: CGFloat = 0.02
    ) -> Set<DisplayID> {
        var resolved: Set<DisplayID> = []
        for screen in screens {
            let ratio = intersectionRatio(globalRect: globalRect, screenFrame: screen.frame)
            if ratio >= primaryThreshold {
                resolved.insert(screen.displayID)
                continue
            }
            if previousDisplayIDs.contains(screen.displayID), ratio >= handoffThreshold {
                resolved.insert(screen.displayID)
            }
        }
        return resolved
    }

    /// Snaps a rect to the pixel grid for a given backing scale to avoid shimmer artifacts.
    static func alignRectToBackingGrid(_ rect: NSRect, scale: CGFloat) -> NSRect {
        guard scale > 0 else { return rect }
        let minX = floor(rect.minX * scale)
        let minY = floor(rect.minY * scale)
        let maxX = ceil(rect.maxX * scale)
        let maxY = ceil(rect.maxY * scale)
        let width = max(0, maxX - minX)
        let height = max(0, maxY - minY)
        guard width > 0, height > 0 else { return .zero }
        return NSRect(
            x: minX / scale,
            y: minY / scale,
            width: width / scale,
            height: height / scale
        )
    }
}
