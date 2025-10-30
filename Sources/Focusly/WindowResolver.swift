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
            cornerRadius: clampCornerRadius(radius, to: frontWindow.frame),
            supplementaryMasks: frontWindow.supplementaryMasks
        )
    }

    guard let snapshot = axActiveWindowSnapshot() else {
        return nil
    }

    return ActiveWindowSnapshot(
        frame: snapshot.frame,
        cornerRadius: clampCornerRadius(snapshot.cornerRadius, to: snapshot.frame),
        supplementaryMasks: resolveSupplementaryMasks(
            primaryPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            excludingWindowNumbers: windowNumbers
        )
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

private struct CGFrontWindowSnapshot {
    let frame: NSRect
    let ownerPID: pid_t
    let windowNumber: Int
    let supplementaryMasks: [ActiveWindowSnapshot.MaskRegion]
}

private func cgFrontWindow(excluding windowNumbers: Set<Int>) -> CGFrontWindowSnapshot? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

    guard let fullList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]], !fullList.isEmpty else {
        return nil
    }

    let shortlist = Array(fullList.prefix(24))
    let front = findFrontWindow(in: shortlist, excluding: windowNumbers) ?? findFrontWindow(in: fullList, excluding: windowNumbers)

    guard let resolvedFront = front else {
        return nil
    }

    let supplementary = collectSupplementaryMasks(
        in: fullList,
        primaryPID: resolvedFront.ownerPID,
        excludingNumbers: windowNumbers.union([resolvedFront.windowNumber])
    )

    return CGFrontWindowSnapshot(
        frame: resolvedFront.frame,
        ownerPID: resolvedFront.ownerPID,
        windowNumber: resolvedFront.windowNumber,
        supplementaryMasks: supplementary
    )
}

private func findFrontWindow(in windows: [[String: Any]], excluding windowNumbers: Set<Int>) -> CGFrontWindowSnapshot? {
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

        return CGFrontWindowSnapshot(
            frame: frame,
            ownerPID: resolvedPID,
            windowNumber: number,
            supplementaryMasks: []
        )
    }
    return nil
}

/// Scans the current window list for secondary surfaces tied to the front application
/// (e.g. context menus or menu-bar dropdowns) so we can carve them out of the overlay.
private func collectSupplementaryMasks(
    in windows: [[String: Any]],
    primaryPID: pid_t?,
    excludingNumbers: Set<Int>
) -> [ActiveWindowSnapshot.MaskRegion] {
    var results: [ActiveWindowSnapshot.MaskRegion] = []
    var seen: Set<Int> = []

    for window in windows {
        guard let number = window[kCGWindowNumber as String] as? Int else { continue }
        if excludingNumbers.contains(number) { continue }
        if seen.contains(number) { continue }
        guard let layer = window[kCGWindowLayer as String] as? Int else { continue }
        if let alpha = window[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
        guard
            let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else {
            continue
        }
        guard bounds.width >= 4, bounds.height >= 4 else { continue }

        let resolvedPID: pid_t?
        if let pidValue = window[kCGWindowOwnerPID as String] as? Int {
            resolvedPID = pid_t(pidValue)
        } else if let pidValue = window[kCGWindowOwnerPID as String] as? pid_t {
            resolvedPID = pidValue
        } else {
            resolvedPID = nil
        }

        let ownerName = window[kCGWindowOwnerName as String] as? String
        let matchesPrimary: Bool
        if let primaryPID {
            matchesPrimary = resolvedPID == primaryPID
        } else {
            matchesPrimary = false
        }

        guard let purpose = classifyMenuWindow(
            layer: layer,
            name: window[kCGWindowName as String] as? String,
            ownerName: ownerName,
            bounds: bounds,
            matchesPrimary: matchesPrimary
        ) else {
            continue
        }

        let correctedBounds = convertCGWindowBoundsToCocoa(bounds)
        let frame = NSRect(
            x: correctedBounds.origin.x,
            y: correctedBounds.origin.y,
            width: correctedBounds.size.width,
            height: correctedBounds.size.height
        )

        let radius = menuCornerRadius(for: frame)

        results.append(
            ActiveWindowSnapshot.MaskRegion(
                frame: frame,
                cornerRadius: radius,
                purpose: purpose
            )
        )
        seen.insert(number)
    }

    return results.sorted { lhs, rhs in
        let lhsOrder = maskPurposeOrder(lhs.purpose)
        let rhsOrder = maskPurposeOrder(rhs.purpose)
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }
        if lhs.frame.origin.y != rhs.frame.origin.y {
            return lhs.frame.origin.y < rhs.frame.origin.y
        }
        if lhs.frame.origin.x != rhs.frame.origin.x {
            return lhs.frame.origin.x < rhs.frame.origin.x
        }
        if lhs.frame.width != rhs.frame.width {
            return lhs.frame.width < rhs.frame.width
        }
        return lhs.frame.height < rhs.frame.height
    }
}

/// Standalone helper used by the AX fallback path to still find menus for the front app.
private func resolveSupplementaryMasks(primaryPID: pid_t?, excludingWindowNumbers: Set<Int>) -> [ActiveWindowSnapshot.MaskRegion] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let fullList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]], !fullList.isEmpty else {
        return []
    }
    return collectSupplementaryMasks(in: fullList, primaryPID: primaryPID, excludingNumbers: excludingWindowNumbers)
}

/// Menu surfaces ship with a subtle rounding; we keep it conservative to avoid bleeding into content.
private func menuCornerRadius(for frame: NSRect) -> CGFloat {
    clampCornerRadius(8, to: frame)
}

private func classifyMenuWindow(
    layer: Int,
    name: String?,
    ownerName: String?,
    bounds: CGRect,
    matchesPrimary: Bool
) -> ActiveWindowSnapshot.MaskRegion.Purpose? {
    if matchesPrimary {
        return .applicationMenu
    }

    if let ownerName, ownerName == "SystemUIServer" {
        return .systemMenu
    }

    let lowercasedName = name?.lowercased() ?? ""
    let area = bounds.width * bounds.height
    let height = bounds.height

    if layer >= 18 {
        return .systemMenu
    }

    if !lowercasedName.isEmpty {
        if lowercasedName.contains("menu") || lowercasedName.contains("popover") || lowercasedName.contains("context") {
            return .systemMenu
        }
    }

    let isCompact = height <= 620 && area <= 520_000
    if isCompact && layer >= 4 {
        return .systemMenu
    }

    return nil
}

private func maskPurposeOrder(_ purpose: ActiveWindowSnapshot.MaskRegion.Purpose) -> Int {
    switch purpose {
    case .applicationWindow:
        return 0
    case .applicationMenu:
        return 1
    case .systemMenu:
        return 2
    }
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
