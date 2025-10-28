import AppKit
import CoreGraphics

/// Resolves the currently focused window frame using the most permissive APIs available.
/// Falls back to accessibility lookups when Core Graphics metadata is not available
/// (e.g. when an app has no on-screen windows).
func resolveActiveWindowFrame(excluding windowNumbers: Set<Int> = []) -> NSRect? {
    if let frame = cgActiveWindowFrame(excluding: windowNumbers) {
        return frame
    }
    return axActiveWindowFrame()
}

/// CoreGraphics-only variant to avoid touching the Accessibility APIs.
func resolveActiveWindowFrameUsingCoreGraphics(excluding windowNumbers: Set<Int> = []) -> NSRect? {
    cgActiveWindowFrame(excluding: windowNumbers)
}

private func cgActiveWindowFrame(excluding windowNumbers: Set<Int>) -> NSRect? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
    let targetPID = frontApp.processIdentifier

    guard let infoList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return nil
    }

    if let frame = findWindow(in: infoList, matchingPID: targetPID, excluding: windowNumbers) {
        return frame
    }

    // Fallback: grab the first visible window that is not part of our overlay stack.
    if let frame = findWindow(in: infoList, matchingPID: nil, excluding: windowNumbers) {
        return frame
    }

    return nil
}

private func findWindow(
    in windows: [[String: Any]],
    matchingPID pid: pid_t?,
    excluding excludedNumbers: Set<Int>
) -> NSRect? {
    for window in windows {
        if let pid, let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t, ownerPID != pid {
            continue
        }

        guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else {
            continue
        }

        if
            let number = window[kCGWindowNumber as String] as? Int,
            excludedNumbers.contains(number)
        {
            continue
        }

        guard
            let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else {
            continue
        }

        guard bounds.width >= 4, bounds.height >= 4 else { continue }

        if let alpha = window[kCGWindowAlpha as String] as? Double, alpha < 0.05 {
            continue
        }

        let correctedBounds = convertCGWindowBoundsToCocoa(bounds)
        return NSRect(
            x: correctedBounds.origin.x,
            y: correctedBounds.origin.y,
            width: correctedBounds.size.width,
            height: correctedBounds.size.height
        )
    }
    return nil
}

private func convertCGWindowBoundsToCocoa(_ bounds: CGRect) -> CGRect {
    guard let targetScreen = screenMatching(bounds) else {
        return bounds
    }

    let screenFrame = targetScreen.frame
    var converted = bounds

    converted.origin.y = (screenFrame.origin.y + screenFrame.size.height) - (bounds.origin.y + bounds.size.height)

    return converted
}

private func screenMatching(_ rect: CGRect) -> NSScreen? {
    var bestMatch: (screen: NSScreen, area: CGFloat)?

    for screen in NSScreen.screens {
        let intersection = screen.frame.intersection(rect)
        guard !intersection.isNull else { continue }
        let area = intersection.size.width * intersection.size.height
        if let current = bestMatch {
            if area > current.area {
                bestMatch = (screen, area)
            }
        } else {
            bestMatch = (screen, area)
        }
    }

    return bestMatch?.screen ?? NSScreen.screens.first
}
