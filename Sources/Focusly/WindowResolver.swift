import AppKit
import CoreGraphics

/// Resolves the currently focused window snapshot using the most permissive APIs available.
/// Falls back to accessibility lookups when Core Graphics metadata is not available
/// (e.g. when an app has no on-screen windows).
func resolveActiveWindowSnapshot(excluding windowNumbers: Set<Int> = []) -> ActiveWindowSnapshot? {
    if let frontWindow = cgFrontWindow(excluding: windowNumbers) {
        let radius = axActiveWindowCornerRadius(preferredPID: frontWindow.ownerPID) ?? fallbackCornerRadius(for: frontWindow.frame)
        return ActiveWindowSnapshot(
            frame: frontWindow.frame,
            cornerRadius: clampCornerRadius(radius, to: frontWindow.frame)
        )
    }

    guard let snapshot = axActiveWindowSnapshot() else {
        return nil
    }

    return ActiveWindowSnapshot(
        frame: snapshot.frame,
        cornerRadius: clampCornerRadius(snapshot.cornerRadius, to: snapshot.frame)
    )
}

/// Resolves the currently focused window frame using the most permissive APIs available.
/// Falls back to accessibility lookups when Core Graphics metadata is not available
/// (e.g. when an app has no on-screen windows).
func resolveActiveWindowFrame(excluding windowNumbers: Set<Int> = []) -> NSRect? {
    if let frontWindow = cgFrontWindow(excluding: windowNumbers) {
        return frontWindow.frame
    }
    return axActiveWindowSnapshot()?.frame
}

/// CoreGraphics-only variant to avoid touching the Accessibility APIs.
func resolveActiveWindowFrameUsingCoreGraphics(excluding windowNumbers: Set<Int> = []) -> NSRect? {
    cgFrontWindow(excluding: windowNumbers)?.frame
}

private struct CGFrontWindow {
    let frame: NSRect
    let ownerPID: pid_t
}

private func cgFrontWindow(excluding windowNumbers: Set<Int>) -> CGFrontWindow? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

    let resolveFrontWindow: ([[String: Any]]) -> CGFrontWindow? = { windows in
        for window in windows {
            guard let number = window[kCGWindowNumber as String] as? Int else { continue }
            if windowNumbers.contains(number) { continue }
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            guard
                let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else {
                continue
            }
            guard bounds.width >= 4, bounds.height >= 4 else { continue }

            let correctedBounds = convertCGWindowBoundsToCocoa(bounds)
            let resolvedPID: pid_t
            if let pidValue = window[kCGWindowOwnerPID as String] as? Int {
                resolvedPID = pid_t(pidValue)
            } else if let pidValue = window[kCGWindowOwnerPID as String] as? pid_t {
                resolvedPID = pidValue
            } else {
                continue
            }

            let frame = NSRect(
                x: correctedBounds.origin.x,
                y: correctedBounds.origin.y,
                width: correctedBounds.size.width,
                height: correctedBounds.size.height
            )

            return CGFrontWindow(frame: frame, ownerPID: resolvedPID)
        }
        return nil
    }

    guard let fullList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]], !fullList.isEmpty else {
        return nil
    }

    let shortlist = Array(fullList.prefix(24))
    if let front = resolveFrontWindow(shortlist) {
        return front
    }

    if let front = resolveFrontWindow(fullList) {
        return front
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

private func clampCornerRadius(_ radius: CGFloat, to frame: NSRect) -> CGFloat {
    guard radius > 0 else { return 0 }
    let maxRadius = min(frame.width, frame.height) / 2
    return min(radius, maxRadius)
}

private func fallbackCornerRadius(for frame: NSRect) -> CGFloat {
    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 {
        return 26
    }
    return 0
}
