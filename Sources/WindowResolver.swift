import AppKit
import CoreGraphics

private let popUpMenuWindowLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
private let floatingAccessoryWindowLevel = Int(CGWindowLevelForKey(.floatingWindow))
private let menuKeywordSet: Set<String> = ["menu", "popover", "context"]

/// Resolves the currently focused window snapshot using the most permissive APIs available.
/// Falls back to accessibility lookups when Core Graphics metadata is not available
/// (e.g. when an app has no on-screen windows).
func resolveActiveWindowSnapshot(
    excluding windowNumbers: Set<Int> = [],
    preferredPID: pid_t? = nil
) -> ActiveWindowSnapshot? {
    if let frontWindow = cgFrontWindow(excluding: windowNumbers, preferredPID: preferredPID) {
        let resolvedCornerRadius = axActiveWindowCornerRadius(preferredPID: frontWindow.ownerPID) ?? fallbackCornerRadius(for: frontWindow.frame)
        return ActiveWindowSnapshot(
            frame: frontWindow.frame,
            cornerRadius: clampCornerRadius(resolvedCornerRadius, to: frontWindow.frame),
            supplementaryMasks: frontWindow.supplementaryMasks
        )
    }

    guard let snapshot = axActiveWindowSnapshot(preferredPID: preferredPID) else {
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
func resolveActiveWindowFrame(
    excluding windowNumbers: Set<Int> = [],
    preferredPID: pid_t? = nil
) -> NSRect? {
    if let frontWindow = cgFrontWindow(excluding: windowNumbers, preferredPID: preferredPID) {
        return frontWindow.frame
    }
    return axActiveWindowSnapshot(preferredPID: preferredPID)?.frame
}

/// CoreGraphics-only variant to avoid touching the Accessibility APIs.
func resolveActiveWindowFrameUsingCoreGraphics(
    excluding windowNumbers: Set<Int> = [],
    preferredPID: pid_t? = nil
) -> NSRect? {
    cgFrontWindow(excluding: windowNumbers, preferredPID: preferredPID)?.frame
}

/// Metadata representing the window currently at the front of the CoreGraphics list.
private struct CGFrontWindowSnapshot {
    let frame: NSRect
    let ownerPID: pid_t
    let windowNumber: Int
    let supplementaryMasks: [ActiveWindowSnapshot.MaskRegion]
}

/// Uses CoreGraphics to locate the foremost visible window while skipping overlay windows.
private func cgFrontWindow(excluding windowNumbers: Set<Int>, preferredPID: pid_t?) -> CGFrontWindowSnapshot? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

    guard let completeWindowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]], !completeWindowList.isEmpty else {
        return nil
    }

    let candidateWindowList = Array(completeWindowList.prefix(24))
    if let preferredPID,
       let preferredFrontWindow = findFrontWindow(in: candidateWindowList, excluding: windowNumbers, preferredPID: preferredPID)
            ?? findFrontWindow(in: completeWindowList, excluding: windowNumbers, preferredPID: preferredPID) {
        let supplementaryRegions = collectSupplementaryMasks(
            in: completeWindowList,
            primaryPID: preferredFrontWindow.ownerPID,
            excludingNumbers: windowNumbers.union([preferredFrontWindow.windowNumber])
        )

        return CGFrontWindowSnapshot(
            frame: preferredFrontWindow.frame,
            ownerPID: preferredFrontWindow.ownerPID,
            windowNumber: preferredFrontWindow.windowNumber,
            supplementaryMasks: supplementaryRegions
        )
    }

    let candidateFrontWindow = findFrontWindow(in: candidateWindowList, excluding: windowNumbers, preferredPID: nil)
        ?? findFrontWindow(in: completeWindowList, excluding: windowNumbers, preferredPID: nil)

    guard let resolvedFrontWindow = candidateFrontWindow else {
        return nil
    }

    let supplementaryRegions = collectSupplementaryMasks(
        in: completeWindowList,
        primaryPID: resolvedFrontWindow.ownerPID,
        excludingNumbers: windowNumbers.union([resolvedFrontWindow.windowNumber])
    )

    return CGFrontWindowSnapshot(
        frame: resolvedFrontWindow.frame,
        ownerPID: resolvedFrontWindow.ownerPID,
        windowNumber: resolvedFrontWindow.windowNumber,
        supplementaryMasks: supplementaryRegions
    )
}

/// Walks window dictionaries looking for the topmost candidate the overlay should carve out.
private func findFrontWindow(
    in windowDictionaries: [[String: Any]],
    excluding windowNumbers: Set<Int>,
    preferredPID: pid_t?
) -> CGFrontWindowSnapshot? {
    var fallbackSnapshot: CGFrontWindowSnapshot?

    for windowDictionary in windowDictionaries {
        guard let windowNumber = windowDictionary[kCGWindowNumber as String] as? Int else { continue }
        if windowNumbers.contains(windowNumber) { continue }
        guard let layerIndex = windowDictionary[kCGWindowLayer as String] as? Int, layerIndex == 0 else { continue }
        if let alphaValue = windowDictionary[kCGWindowAlpha as String] as? Double, alphaValue < 0.05 { continue }
        guard
            let boundsDictionary = windowDictionary[kCGWindowBounds as String] as? [String: Any],
            let coreGraphicsBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
        else {
            continue
        }
        guard coreGraphicsBounds.width >= 4, coreGraphicsBounds.height >= 4 else { continue }

        let correctedBounds = convertCGWindowBoundsToCocoa(coreGraphicsBounds)
        let resolvedProcessID: pid_t
        if let pidValue = windowDictionary[kCGWindowOwnerPID as String] as? Int {
            resolvedProcessID = pid_t(pidValue)
        } else if let pidValue = windowDictionary[kCGWindowOwnerPID as String] as? pid_t {
            resolvedProcessID = pidValue
        } else {
            continue
        }

        let cocoaFrame = NSRect(
            x: correctedBounds.origin.x,
            y: correctedBounds.origin.y,
            width: correctedBounds.size.width,
            height: correctedBounds.size.height
        )

        let snapshot = CGFrontWindowSnapshot(
            frame: cocoaFrame,
            ownerPID: resolvedProcessID,
            windowNumber: windowNumber,
            supplementaryMasks: []
        )

        if let preferredPID, resolvedProcessID == preferredPID {
            return snapshot
        }
        if fallbackSnapshot == nil {
            fallbackSnapshot = snapshot
        }
    }
    return fallbackSnapshot
}

/// Scans the current window list for secondary surfaces tied to the front application
/// (e.g. context menus or menu-bar dropdowns) so we can carve them out of the overlay.
private func collectSupplementaryMasks(
    in windowDictionaries: [[String: Any]],
    primaryPID: pid_t?,
    excludingNumbers: Set<Int>
) -> [ActiveWindowSnapshot.MaskRegion] {
    var maskRegions: [ActiveWindowSnapshot.MaskRegion] = []
    var visitedWindowNumbers: Set<Int> = []

    for window in windowDictionaries {
        guard let number = window[kCGWindowNumber as String] as? Int else { continue }
        if excludingNumbers.contains(number) { continue }
        if visitedWindowNumbers.contains(number) { continue }
        guard let layerIndex = window[kCGWindowLayer as String] as? Int else { continue }
        if let alphaValue = window[kCGWindowAlpha as String] as? Double, alphaValue < 0.05 { continue }
        guard
            let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
            let coreGraphicsBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
        else {
            continue
        }
        guard coreGraphicsBounds.width >= 4, coreGraphicsBounds.height >= 4 else { continue }

        let resolvedProcessID: pid_t?
        if let pidValue = window[kCGWindowOwnerPID as String] as? Int {
            resolvedProcessID = pid_t(pidValue)
        } else if let pidValue = window[kCGWindowOwnerPID as String] as? pid_t {
            resolvedProcessID = pidValue
        } else {
            resolvedProcessID = nil
        }

        let ownerApplicationName = window[kCGWindowOwnerName as String] as? String
        let matchesPrimary: Bool
        if let primaryPID {
            matchesPrimary = resolvedProcessID == primaryPID
        } else {
            matchesPrimary = false
        }

        guard let maskPurpose = classifyMenuWindow(
            layer: layerIndex,
            name: window[kCGWindowName as String] as? String,
            ownerName: ownerApplicationName,
            bounds: coreGraphicsBounds,
            matchesPrimary: matchesPrimary
        ) else {
            continue
        }

        let correctedBounds = convertCGWindowBoundsToCocoa(coreGraphicsBounds)
        let maskFrame = NSRect(
            x: correctedBounds.origin.x,
            y: correctedBounds.origin.y,
            width: correctedBounds.size.width,
            height: correctedBounds.size.height
        )

        let cornerRadius = menuCornerRadius(for: maskFrame)

        maskRegions.append(
            ActiveWindowSnapshot.MaskRegion(
                frame: maskFrame,
                cornerRadius: cornerRadius,
                purpose: maskPurpose
            )
        )
        visitedWindowNumbers.insert(number)
    }

    return maskRegions.sorted { lhs, rhs in
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
    let windowListOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let completeWindowList = CGWindowListCopyWindowInfo(windowListOptions, kCGNullWindowID) as? [[String: Any]], !completeWindowList.isEmpty else {
        return []
    }
    return collectSupplementaryMasks(in: completeWindowList, primaryPID: primaryPID, excludingNumbers: excludingWindowNumbers)
}

/// Menu surfaces ship with a subtle rounding; we keep it conservative to avoid bleeding into content.
private func menuCornerRadius(for maskFrame: NSRect) -> CGFloat {
    clampCornerRadius(8, to: maskFrame)
}

/// Heuristically identifies whether a window should be treated as a menu carve-out.
private func classifyMenuWindow(
    layer layerIndex: Int,
    name windowName: String?,
    ownerName ownerApplicationName: String?,
    bounds coreGraphicsBounds: CGRect,
    matchesPrimary matchesPrimaryApplication: Bool
) -> ActiveWindowSnapshot.MaskRegion.Purpose? {
    if matchesPrimaryApplication {
        return .applicationMenu
    }

    if let ownerApplicationName, ownerApplicationName == "SystemUIServer" {
        return .systemMenu
    }

    let lowercasedOwnerName = ownerApplicationName?.lowercased() ?? ""
    if menuKeywordSet.contains(where: { lowercasedOwnerName.contains($0) }) {
        return .systemMenu
    }

    let lowercasedName = windowName?.lowercased() ?? ""
    let windowArea = coreGraphicsBounds.width * coreGraphicsBounds.height
    let windowHeight = coreGraphicsBounds.height
    let windowWidth = coreGraphicsBounds.width

    if layerIndex >= popUpMenuWindowLevel && popUpMenuWindowLevel > 0 {
        return .systemMenu
    }

    if layerIndex >= 18 {
        return .systemMenu
    }

    if !lowercasedName.isEmpty, menuKeywordSet.contains(where: { lowercasedName.contains($0) }) {
        return .systemMenu
    }

    let isCompactMenu = windowHeight <= 620 && windowArea <= 520_000
    let isTallNarrowMenu = windowArea <= 900_000 && windowWidth <= 420
    let compactWindowOnFloatingLayer = layerIndex >= max(2, floatingAccessoryWindowLevel)

    if (isCompactMenu || isTallNarrowMenu) && compactWindowOnFloatingLayer {
        return .systemMenu
    }

    if (isCompactMenu || isTallNarrowMenu), lowercasedOwnerName.isEmpty, layerIndex == 0 {
        return .systemMenu
    }

    if isCompactMenu && layerIndex >= 4 {
        return .systemMenu
    }

    return nil
}

/// Provides a stable ordering so mask regions sort consistently.
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

/// Converts CoreGraphics window coordinates to Cocoa coordinates for the correct screen.
private func convertCGWindowBoundsToCocoa(_ bounds: CGRect) -> CGRect {
    guard let targetScreen = screenMatching(bounds) else {
        return bounds
    }

    let screenFrame = targetScreen.frame
    var converted = bounds

    converted.origin.y = (screenFrame.origin.y + screenFrame.size.height) - (bounds.origin.y + bounds.size.height)

    return converted
}

/// Finds the screen whose frame contains the largest portion of the supplied rect.
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

/// Clamps a corner radius so it never exceeds half the window dimensions.
private func clampCornerRadius(_ radius: CGFloat, to frame: NSRect) -> CGFloat {
    guard radius > 0 else { return 0 }
    let maxRadius = min(frame.width, frame.height) / 2
    return min(radius, maxRadius)
}

/// Provides a conservative default corner radius for macOS versions that hide the value.
private func fallbackCornerRadius(for frame: NSRect) -> CGFloat {
    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 {
        return 26
    }
    return 0
}
