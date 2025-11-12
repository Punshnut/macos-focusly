import AppKit
import CoreGraphics

private let popUpMenuWindowLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
private let floatingAccessoryWindowLevel = Int(CGWindowLevelForKey(.floatingWindow))
private let menuKeywordSet: Set<String> = ["menu", "popover", "context"]

/// Cardinal direction describing which screen edge a peripheral element hugs.
enum PeripheralEdge: Equatable {
    case leading
    case trailing
    case top
    case bottom
}

/// Describes system surfaces such as the Dock or Stage Manager shelf so overlays can treat them like carve-outs.
struct PeripheralInterfaceRegion: Equatable {
    enum Kind: Equatable {
        case dock(edge: PeripheralEdge, isAutoHidden: Bool)
        case stageManagerShelf(edge: PeripheralEdge)
    }

    let displayID: DisplayID
    let frame: NSRect
    let hoverRect: NSRect
    let cornerRadius: CGFloat
    let kind: Kind
}

/// Snapshot of the current Dock preferences we care about for overlay carve-outs.
struct DockConfiguration: Equatable {
    let orientation: PeripheralEdge
    let autohide: Bool
    let tileSize: CGFloat
}

@MainActor
func systemDockConfiguration() -> DockConfiguration {
    let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
    let autohide = dockDefaults?.object(forKey: "autohide") as? Bool ?? false
    let tileSizeValue = dockDefaults?.object(forKey: "tilesize") as? Double ?? 64
    let rawOrientation = (dockDefaults?.string(forKey: "orientation") ?? "bottom").lowercased()
    let orientation: PeripheralEdge
    switch rawOrientation {
    case "left": orientation = .leading
    case "right": orientation = .trailing
    case "top": orientation = .top
    default: orientation = .bottom
    }
    return DockConfiguration(
        orientation: orientation,
        autohide: autohide,
        tileSize: CGFloat(max(32, min(96, tileSizeValue)))
    )
}

/// Resolves the currently focused window snapshot using the most permissive APIs available.
/// Falls back to accessibility lookups when Core Graphics metadata is not available
/// (e.g. when an app has no on-screen windows).
@MainActor
func resolveActiveWindowSnapshot(
    excluding windowNumbers: Set<Int> = [],
    preferredPID: pid_t? = nil,
    includeAllApplicationWindows: Bool = true
) -> ActiveWindowSnapshot? {
    let resolvedPreferredPID = resolvedPreferredProcessIdentifier(preferredPID)

    if let frontWindow = cgFrontWindow(
        excluding: windowNumbers,
        preferredPID: resolvedPreferredPID,
        includeApplicationWindows: includeAllApplicationWindows
    ) {
        let resolvedCornerRadius = (
            frontWindow.cornerRadius ??
            axActiveWindowCornerRadius(preferredPID: frontWindow.ownerPID) ??
            fallbackCornerRadius(for: frontWindow.frame)
        )
        return ActiveWindowSnapshot(
            frame: frontWindow.frame,
            cornerRadius: clampCornerRadius(resolvedCornerRadius, to: frontWindow.frame),
            supplementaryMasks: frontWindow.supplementaryMasks
        )
    }

    guard let snapshot = axActiveWindowSnapshot(preferredPID: resolvedPreferredPID) else {
        return nil
    }

    if resolvedPreferredPID == nil, isFrontmostApplicationIgnoredForMasking() {
        return nil
    }

    let supplementaryMasks = resolveSupplementaryMasks(
        primaryPID: frontmostApplicationProcessIdentifierForMasking(),
        excludingWindowNumbers: windowNumbers,
        includeApplicationWindows: includeAllApplicationWindows
    )

    return ActiveWindowSnapshot(
        frame: snapshot.frame,
        cornerRadius: clampCornerRadius(snapshot.cornerRadius, to: snapshot.frame),
        supplementaryMasks: supplementaryMasks
    )
}

/// Resolves the currently focused window frame using the most permissive APIs available.
/// Falls back to accessibility lookups when Core Graphics metadata is not available
/// (e.g. when an app has no on-screen windows).
@MainActor
func resolveActiveWindowFrame(
    excluding windowNumbers: Set<Int> = [],
    preferredPID: pid_t? = nil
) -> NSRect? {
    let resolvedPreferredPID = resolvedPreferredProcessIdentifier(preferredPID)
    if let frontWindow = cgFrontWindow(excluding: windowNumbers, preferredPID: resolvedPreferredPID) {
        return frontWindow.frame
    }
    return axActiveWindowSnapshot(preferredPID: resolvedPreferredPID)?.frame
}

/// CoreGraphics-only variant to avoid touching the Accessibility APIs.
@MainActor
func resolveActiveWindowFrameUsingCoreGraphics(
    excluding windowNumbers: Set<Int> = [],
    preferredPID: pid_t? = nil
) -> NSRect? {
    let resolvedPreferredPID = resolvedPreferredProcessIdentifier(preferredPID)
    return cgFrontWindow(excluding: windowNumbers, preferredPID: resolvedPreferredPID)?.frame
}

/// Metadata representing the window currently at the front of the CoreGraphics list.
private struct CGFrontWindowSnapshot {
    let frame: NSRect
    let ownerPID: pid_t
    let windowNumber: Int
    let cornerRadius: CGFloat?
    let supplementaryMasks: [ActiveWindowSnapshot.MaskRegion]
}

/// Uses CoreGraphics to locate the foremost visible window while skipping overlay windows.
@MainActor
private func cgFrontWindow(
    excluding windowNumbers: Set<Int>,
    preferredPID: pid_t?,
    includeApplicationWindows: Bool = true
) -> CGFrontWindowSnapshot? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]

    guard let completeWindowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]], !completeWindowList.isEmpty else {
        return nil
    }

    var cornerSnapshotCache: [pid_t: [AXWindowCornerSnapshot]] = [:]
    var bundleIdentifierCache: [pid_t: String?] = [:]

    let candidateWindowList = Array(completeWindowList.prefix(24))
    let resolvedPreferredPID: pid_t? = {
        if let preferredPID {
            return preferredPID
        }
        return frontmostApplicationProcessIdentifierForMasking()
    }()

    if let targetPID = resolvedPreferredPID,
       let preferredFrontWindow = findFrontWindow(
           in: candidateWindowList,
           excluding: windowNumbers,
           preferredPID: targetPID,
           bundleIdentifierCache: &bundleIdentifierCache,
           cornerSnapshotCache: &cornerSnapshotCache
       ) ?? findFrontWindow(
           in: completeWindowList,
           excluding: windowNumbers,
           preferredPID: targetPID,
           bundleIdentifierCache: &bundleIdentifierCache,
           cornerSnapshotCache: &cornerSnapshotCache
       ) {
        let supplementaryRegions = collectSupplementaryMasks(
            in: completeWindowList,
            primaryPID: preferredFrontWindow.ownerPID,
            excludingNumbers: windowNumbers.union([preferredFrontWindow.windowNumber]),
            includeApplicationWindows: includeApplicationWindows,
            cornerSnapshotCache: &cornerSnapshotCache,
            bundleIdentifierCache: &bundleIdentifierCache
        )

        let resolvedCornerRadius = resolveCornerRadiusForWindow(
            pid: preferredFrontWindow.ownerPID,
            frame: preferredFrontWindow.frame,
            cache: &cornerSnapshotCache
        )

        return CGFrontWindowSnapshot(
            frame: preferredFrontWindow.frame,
            ownerPID: preferredFrontWindow.ownerPID,
            windowNumber: preferredFrontWindow.windowNumber,
            cornerRadius: resolvedCornerRadius,
            supplementaryMasks: supplementaryRegions
        )
    }

    let candidateFrontWindow = findFrontWindow(
        in: candidateWindowList,
        excluding: windowNumbers,
        preferredPID: nil,
        bundleIdentifierCache: &bundleIdentifierCache,
        cornerSnapshotCache: &cornerSnapshotCache
    ) ?? findFrontWindow(
        in: completeWindowList,
        excluding: windowNumbers,
        preferredPID: nil,
        bundleIdentifierCache: &bundleIdentifierCache,
        cornerSnapshotCache: &cornerSnapshotCache
    )

    guard let resolvedFrontWindow = candidateFrontWindow else {
        return nil
    }

    let supplementaryRegions = collectSupplementaryMasks(
        in: completeWindowList,
        primaryPID: resolvedFrontWindow.ownerPID,
        excludingNumbers: windowNumbers.union([resolvedFrontWindow.windowNumber]),
        includeApplicationWindows: includeApplicationWindows,
        cornerSnapshotCache: &cornerSnapshotCache,
        bundleIdentifierCache: &bundleIdentifierCache
    )

    let resolvedCornerRadius = resolveCornerRadiusForWindow(
        pid: resolvedFrontWindow.ownerPID,
        frame: resolvedFrontWindow.frame,
        cache: &cornerSnapshotCache
    )

    return CGFrontWindowSnapshot(
        frame: resolvedFrontWindow.frame,
        ownerPID: resolvedFrontWindow.ownerPID,
        windowNumber: resolvedFrontWindow.windowNumber,
        cornerRadius: resolvedCornerRadius,
        supplementaryMasks: supplementaryRegions
    )
}

/// Walks window dictionaries looking for the topmost candidate the overlay should carve out.
@MainActor
private func findFrontWindow(
    in windowDictionaries: [[String: Any]],
    excluding windowNumbers: Set<Int>,
    preferredPID: pid_t?,
    bundleIdentifierCache: inout [pid_t: String?],
    cornerSnapshotCache: inout [pid_t: [AXWindowCornerSnapshot]]
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
        let cocoaFrame = NSRect(
            x: correctedBounds.origin.x,
            y: correctedBounds.origin.y,
            width: correctedBounds.size.width,
            height: correctedBounds.size.height
        )

        let resolvedProcessID: pid_t
        if let pidValue = windowDictionary[kCGWindowOwnerPID as String] as? Int {
            resolvedProcessID = pid_t(pidValue)
        } else if let pidValue = windowDictionary[kCGWindowOwnerPID as String] as? pid_t {
            resolvedProcessID = pidValue
        } else {
            continue
        }

        let ownerApplicationName = windowDictionary[kCGWindowOwnerName as String] as? String
        let resolvedWindowName = resolveWindowName(
            providedName: windowDictionary[kCGWindowName as String] as? String,
            pid: resolvedProcessID,
            frame: cocoaFrame,
            cornerSnapshotCache: &cornerSnapshotCache
        )
        if shouldIgnoreWindowForMasking(
            pid: resolvedProcessID,
            ownerName: ownerApplicationName,
            windowName: resolvedWindowName,
            bundleIdentifierCache: &bundleIdentifierCache
        ) {
            continue
        }

        let snapshot = CGFrontWindowSnapshot(
            frame: cocoaFrame,
            ownerPID: resolvedProcessID,
            windowNumber: windowNumber,
            cornerRadius: nil,
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

/// Scans the CoreGraphics window list for secondary surfaces tied to the front application
/// (e.g. menus, context menus, or popovers) so the overlay can carve them out.
@MainActor
private func collectSupplementaryMasks(
    in windowDictionaries: [[String: Any]],
    primaryPID: pid_t?,
    excludingNumbers: Set<Int>,
    includeApplicationWindows: Bool,
    cornerSnapshotCache: inout [pid_t: [AXWindowCornerSnapshot]],
    bundleIdentifierCache: inout [pid_t: String?]
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

        let correctedBounds = convertCGWindowBoundsToCocoa(coreGraphicsBounds)
        let maskFrame = NSRect(
            x: correctedBounds.origin.x,
            y: correctedBounds.origin.y,
            width: correctedBounds.size.width,
            height: correctedBounds.size.height
        )

        let resolvedProcessID: pid_t?
        if let pidValue = window[kCGWindowOwnerPID as String] as? Int {
            resolvedProcessID = pid_t(pidValue)
        } else if let pidValue = window[kCGWindowOwnerPID as String] as? pid_t {
            resolvedProcessID = pidValue
        } else {
            resolvedProcessID = nil
        }

        let ownerApplicationName = window[kCGWindowOwnerName as String] as? String
        let resolvedWindowName = resolveWindowName(
            providedName: window[kCGWindowName as String] as? String,
            pid: resolvedProcessID,
            frame: maskFrame,
            cornerSnapshotCache: &cornerSnapshotCache
        )
        if shouldIgnoreWindowForMasking(
            pid: resolvedProcessID,
            ownerName: ownerApplicationName,
            windowName: resolvedWindowName,
            bundleIdentifierCache: &bundleIdentifierCache
        ) {
            continue
        }
        let normalizedOwnerName = ownerApplicationName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if normalizedOwnerName == "window server" || normalizedOwnerName == "windowserver" {
            continue
        }
        let matchesPrimary: Bool
        if let primaryPID {
            matchesPrimary = resolvedProcessID == primaryPID
        } else {
            matchesPrimary = false
        }

        guard let maskPurpose = classifySupplementaryWindow(
            layer: layerIndex,
            name: resolvedWindowName,
            ownerName: ownerApplicationName,
            bounds: coreGraphicsBounds,
            matchesPrimary: matchesPrimary,
            includeApplicationWindows: includeApplicationWindows
        ) else {
            continue
        }

        let resolvedCornerRadius: CGFloat
        if let resolvedProcessID,
           let matchedRadius = resolveCornerRadiusForWindow(
               pid: resolvedProcessID,
               frame: maskFrame,
               cache: &cornerSnapshotCache
           ) {
            resolvedCornerRadius = clampCornerRadius(matchedRadius, to: maskFrame)
        } else {
            switch maskPurpose {
            case .applicationWindow:
                resolvedCornerRadius = fallbackCornerRadius(for: maskFrame)
            case .applicationMenu, .systemMenu:
                resolvedCornerRadius = menuCornerRadius(for: maskFrame)
            }
        }

        maskRegions.append(
            ActiveWindowSnapshot.MaskRegion(
                frame: maskFrame,
                cornerRadius: resolvedCornerRadius,
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

/// Resolves a close-match corner radius for a supplementary window by caching AX window snapshots.
@MainActor
private func resolveCornerRadiusForWindow(
    pid: pid_t,
    frame: NSRect,
    cache: inout [pid_t: [AXWindowCornerSnapshot]]
) -> CGFloat? {
    let snapshots = windowCornerSnapshots(for: pid, cache: &cache)

    guard let match = snapshots.first(where: { $0.frame.isApproximatelyEqual(to: frame, tolerance: 3) }) else {
        return nil
    }
    if let radius = match.cornerRadius, radius > 0.1 {
        return radius
    }
    return nil
}

@MainActor
private func windowCornerSnapshots(
    for pid: pid_t,
    cache: inout [pid_t: [AXWindowCornerSnapshot]]
) -> [AXWindowCornerSnapshot] {
    if let cachedSnapshots = cache[pid] {
        return cachedSnapshots
    }
    let fetchedSnapshots = axWindowCornerSnapshots(for: pid)
    cache[pid] = fetchedSnapshots
    return fetchedSnapshots
}

/// Standalone helper used by the AX fallback path to still find menus for the front app.
@MainActor
private func resolveSupplementaryMasks(
    primaryPID: pid_t?,
    excludingWindowNumbers: Set<Int>,
    includeApplicationWindows: Bool
) -> [ActiveWindowSnapshot.MaskRegion] {
    let windowListOptions: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let completeWindowList = CGWindowListCopyWindowInfo(windowListOptions, kCGNullWindowID) as? [[String: Any]], !completeWindowList.isEmpty else {
        return []
    }
    var cornerSnapshotCache: [pid_t: [AXWindowCornerSnapshot]] = [:]
    var bundleIdentifierCache: [pid_t: String?] = [:]
    return collectSupplementaryMasks(
        in: completeWindowList,
        primaryPID: primaryPID,
        excludingNumbers: excludingWindowNumbers,
        includeApplicationWindows: includeApplicationWindows,
        cornerSnapshotCache: &cornerSnapshotCache,
        bundleIdentifierCache: &bundleIdentifierCache
    )
}

/// Expands existing rectangles so neighboring system surfaces are merged together.
private func mergePeripheralRegion(_ rect: CGRect, into existing: CGRect?) -> CGRect {
    var expanded = rect
    expanded = expanded.insetBy(dx: -8, dy: -8)
    if expanded.width <= 0 || expanded.height <= 0 {
        expanded = rect
    }
    if var current = existing {
        current = current.union(expanded)
        return current
    }
    return expanded
}

/// Builds a placeholder Dock region when the system hides it until hovered.
@MainActor
private func syntheticDockRegion(using configuration: DockConfiguration) -> PeripheralInterfaceRegion? {
    guard configuration.autohide else { return nil }
    guard let screen = NSScreen.main,
          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
        return nil
    }
    let displayID = DisplayID(truncating: number)
    let frame = estimatedDockFrame(on: screen, orientation: configuration.orientation, tileSize: configuration.tileSize)
    return makePeripheralRegion(
        displayID: displayID,
        rect: frame,
        kind: .dock(edge: configuration.orientation, isAutoHidden: true)
    )
}

private func estimatedDockFrame(on screen: NSScreen, orientation: PeripheralEdge, tileSize: CGFloat) -> CGRect {
    let screenFrame = screen.frame
    let menuBarHeight = max(0, screenFrame.maxY - screen.visibleFrame.maxY)
    let thickness = min(max(tileSize + 28, 72), orientation == .bottom || orientation == .top ? screenFrame.height * 0.35 : screenFrame.width * 0.35)
    switch orientation {
    case .bottom:
        return CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: thickness
        )
    case .top:
        return CGRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - thickness,
            width: screenFrame.width,
            height: thickness
        )
    case .leading:
        return CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: thickness,
            height: screenFrame.height - menuBarHeight
        )
    case .trailing:
        return CGRect(
            x: screenFrame.maxX - thickness,
            y: screenFrame.minY,
            width: thickness,
            height: screenFrame.height - menuBarHeight
        )
    }
}

/// Builds a typed region with sane hover padding and corner radius values for overlays.
private func makePeripheralRegion(
    displayID: DisplayID,
    rect: CGRect,
    kind: PeripheralInterfaceRegion.Kind
) -> PeripheralInterfaceRegion {
    let frame = NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    let (insetX, insetY, cornerRadius) = hoverInsetsAndCornerRadius(for: frame, kind: kind)
    let hoverRect = frame.insetBy(dx: -insetX, dy: -insetY)
    return PeripheralInterfaceRegion(
        displayID: displayID,
        frame: frame,
        hoverRect: hoverRect,
        cornerRadius: cornerRadius,
        kind: kind
    )
}

private func hoverInsetsAndCornerRadius(for frame: NSRect, kind: PeripheralInterfaceRegion.Kind) -> (CGFloat, CGFloat, CGFloat) {
    let minDimension = max(1, min(frame.width, frame.height))
    switch kind {
    case .dock(let edge, let isAutoHidden):
        let baseCorner = min(24, minDimension / 2)
        let baseInset: CGFloat = isAutoHidden ? 32 : 18
        switch edge {
        case .bottom, .top:
            return (max(baseInset, 22), baseInset, baseCorner)
        case .leading, .trailing:
            return (baseInset, max(baseInset, 24), baseCorner)
        }
    case .stageManagerShelf(let edge):
        let corner = min(30, minDimension / 2)
        switch edge {
        case .leading:
            return (38, 34, corner)
        case .trailing:
            return (38, 34, corner)
        case .top, .bottom:
            return (34, 34, corner)
        }
    }
}

/// Heuristically separates Dock vs. Stage Manager windows owned by the Dock process.
private enum PeripheralWindowClassification {
    case dock(edge: PeripheralEdge)
    case stageManagerShelf(edge: PeripheralEdge)
}

/// Identifies Dock/Stage Manager surfaces owned by the Dock process.
private func classifyPeripheralWindow(
    frame: CGRect,
    screenFrame: CGRect,
    layerIndex: Int,
    ownerName: String
) -> PeripheralWindowClassification? {
    guard frame.width >= 16, frame.height >= 16 else { return nil }

    let edgeTolerance: CGFloat = 90
    let nearLeft = abs(frame.minX - screenFrame.minX) <= edgeTolerance
    let nearRight = abs(frame.maxX - screenFrame.maxX) <= edgeTolerance
    let nearBottom = abs(frame.minY - screenFrame.minY) <= edgeTolerance

    let width = max(frame.width, 1)
    let height = max(frame.height, 1)
    let screenWidth = max(screenFrame.width, 1)
    let screenHeight = max(screenFrame.height, 1)
    let widthRatio = width / screenWidth
    let heightRatio = height / screenHeight

    let normalizedOwner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedOwner == "Dock" {
        let horizontalDock = nearBottom && widthRatio >= 0.18 && heightRatio <= 0.5
        let verticalDock = (nearLeft || nearRight) && heightRatio >= 0.18 && widthRatio <= 0.28
        if horizontalDock {
            return .dock(edge: .bottom)
        }
        if verticalDock {
            return .dock(edge: nearLeft ? .leading : .trailing)
        }

        let avoidsBottomEdge = frame.minY >= screenFrame.minY + 28
        let avoidsTopEdge = frame.maxY <= screenFrame.maxY - 28
        let shelfAligned = (nearLeft || nearRight) && avoidsBottomEdge && avoidsTopEdge
        let shelfWidthOK = widthRatio <= 0.6 && widthRatio >= 0.05
        let shelfHeightOK = heightRatio >= 0.18 && heightRatio <= 0.95
        let shelfLayer = layerIndex >= max(4, floatingAccessoryWindowLevel - 2)
        if shelfAligned && shelfWidthOK && shelfHeightOK && shelfLayer {
            return .stageManagerShelf(edge: nearLeft ? .leading : .trailing)
        }
    }

    return nil
}

/// Resolves Dock and Stage Manager shelf surfaces so overlays can selectively carve them out.
@MainActor
func resolvePeripheralInterfaceRegions(
    excluding windowNumbers: Set<Int> = []
) -> [PeripheralInterfaceRegion] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windowDictionaries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]], !windowDictionaries.isEmpty else {
        return []
    }

    let dockConfiguration = systemDockConfiguration()
    var dockRegions: [DisplayID: CGRect] = [:]
    var dockEdges: [DisplayID: PeripheralEdge] = [:]
    var stageRegions: [DisplayID: CGRect] = [:]
    var stageEdges: [DisplayID: PeripheralEdge] = [:]

    for window in windowDictionaries {
        guard let windowNumber = window[kCGWindowNumber as String] as? Int else { continue }
        if windowNumbers.contains(windowNumber) { continue }

        guard let ownerName = window[kCGWindowOwnerName as String] as? String, ownerName == "Dock" else { continue }
        guard
            let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
            let cgBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
        else {
            continue
        }
        guard cgBounds.width >= 24, cgBounds.height >= 24 else { continue }

        let cocoaBounds = convertCGWindowBoundsToCocoa(cgBounds)
        guard let targetScreen = screenMatching(cocoaBounds),
              let screenNumber = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            continue
        }

        let displayID = DisplayID(truncating: screenNumber)
        let layerIndex = window[kCGWindowLayer as String] as? Int ?? 0

        guard let classification = classifyPeripheralWindow(
            frame: cocoaBounds,
            screenFrame: targetScreen.frame,
            layerIndex: layerIndex,
            ownerName: ownerName
        ) else {
            continue
        }

        switch classification {
        case .dock(let edge):
            dockRegions[displayID] = mergePeripheralRegion(cocoaBounds, into: dockRegions[displayID])
            dockEdges[displayID] = edge
        case .stageManagerShelf(let edge):
            stageRegions[displayID] = mergePeripheralRegion(cocoaBounds, into: stageRegions[displayID])
            stageEdges[displayID] = edge
        }
    }

    var resolvedRegions: [PeripheralInterfaceRegion] = []
    for (displayID, rect) in dockRegions {
        let edge = dockEdges[displayID] ?? dockConfiguration.orientation
        resolvedRegions.append(makePeripheralRegion(
            displayID: displayID,
            rect: rect,
            kind: .dock(edge: edge, isAutoHidden: dockConfiguration.autohide)
        ))
    }
    for (displayID, rect) in stageRegions {
        let edge = stageEdges[displayID] ?? .leading
        resolvedRegions.append(makePeripheralRegion(
            displayID: displayID,
            rect: rect,
            kind: .stageManagerShelf(edge: edge)
        ))
    }

    if dockRegions.isEmpty, dockConfiguration.autohide,
       let syntheticDock = syntheticDockRegion(using: dockConfiguration) {
        resolvedRegions.append(syntheticDock)
    }

    return resolvedRegions.sorted { lhs, rhs in
        if lhs.displayID != rhs.displayID {
            return lhs.displayID < rhs.displayID
        }
        if lhs.frame.origin.x != rhs.frame.origin.x {
            return lhs.frame.origin.x < rhs.frame.origin.x
        }
        return lhs.frame.origin.y < rhs.frame.origin.y
    }
}

/// Menu surfaces ship with a subtle rounding; we keep it conservative to avoid bleeding into content.
private func menuCornerRadius(for maskFrame: NSRect) -> CGFloat {
    guard let screen = screenMatching(maskFrame) else {
        return clampCornerRadius(8, to: maskFrame)
    }

    let menuBarHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    guard menuBarHeight > 0 else {
        return clampCornerRadius(8, to: maskFrame)
    }

    let topAlignmentTolerance: CGFloat = 2
    let widthTolerance: CGFloat = 8
    let heightTolerance: CGFloat = 6

    let isTopAligned = abs(maskFrame.maxY - screen.frame.maxY) <= topAlignmentTolerance
    let isLeftAligned = abs(maskFrame.minX - screen.frame.minX) <= topAlignmentTolerance
    let isRightAligned = abs(maskFrame.maxX - screen.frame.maxX) <= topAlignmentTolerance || maskFrame.width >= screen.frame.width - widthTolerance
    let matchesHeight = abs(maskFrame.height - menuBarHeight) <= heightTolerance || maskFrame.height >= menuBarHeight - heightTolerance

    if isTopAligned && isLeftAligned && isRightAligned && matchesHeight {
        return 0
    }

    return clampCornerRadius(8, to: maskFrame)
}

/// Heuristically identifies whether a window should be treated as an application window or menu carve-out.
private func classifySupplementaryWindow(
    layer layerIndex: Int,
    name windowName: String?,
    ownerName ownerApplicationName: String?,
    bounds coreGraphicsBounds: CGRect,
    matchesPrimary matchesPrimaryApplication: Bool,
    includeApplicationWindows: Bool
) -> ActiveWindowSnapshot.MaskRegion.Purpose? {
    if matchesPrimaryApplication {
        if isLikelyMenuWindow(
            layer: layerIndex,
            name: windowName,
            ownerName: ownerApplicationName,
            bounds: coreGraphicsBounds
        ) {
            return .applicationMenu
        }
        return includeApplicationWindows ? .applicationWindow : nil
    }

    if let ownerApplicationName, ownerApplicationName == "SystemUIServer" {
        return .systemMenu
    }

    if isLikelyMenuWindow(
        layer: layerIndex,
        name: windowName,
        ownerName: ownerApplicationName,
        bounds: coreGraphicsBounds
    ) {
        return .systemMenu
    }

    return nil
}

/// Shared heuristics for identifying popovers, menus, and other transient UI surfaces.
private func isLikelyMenuWindow(
    layer layerIndex: Int,
    name windowName: String?,
    ownerName ownerApplicationName: String?,
    bounds coreGraphicsBounds: CGRect
) -> Bool {
    let lowercasedOwnerName = ownerApplicationName?.lowercased() ?? ""
    if menuKeywordSet.contains(where: { lowercasedOwnerName.contains($0) }) {
        return true
    }

    if layerIndex >= popUpMenuWindowLevel && popUpMenuWindowLevel > 0 {
        return true
    }

    if layerIndex >= 18 {
        return true
    }

    let lowercasedName = windowName?.lowercased() ?? ""
    if !lowercasedName.isEmpty, menuKeywordSet.contains(where: { lowercasedName.contains($0) }) {
        return true
    }

    let windowArea = coreGraphicsBounds.width * coreGraphicsBounds.height
    let windowHeight = coreGraphicsBounds.height
    let windowWidth = coreGraphicsBounds.width

    let isCompactMenu = windowHeight <= 620 && windowArea <= 520_000
    let isTallNarrowMenu = windowArea <= 900_000 && windowWidth <= 420
    let compactWindowOnFloatingLayer = layerIndex >= max(2, floatingAccessoryWindowLevel)

    if (isCompactMenu || isTallNarrowMenu) && compactWindowOnFloatingLayer {
        return true
    }

    if (isCompactMenu || isTallNarrowMenu), lowercasedOwnerName.isEmpty, layerIndex == 0 {
        return true
    }

    if isCompactMenu && layerIndex >= 4 {
        return true
    }

    return false
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
    guard
        let targetScreen = screenMatching(bounds),
        let screenNumber = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else {
        return bounds
    }

    let displayID = CGDirectDisplayID(screenNumber.uint32Value)
    let displayBounds = CGDisplayBounds(displayID)

    let displayWidth = max(displayBounds.width, 1)
    let displayHeight = max(displayBounds.height, 1)

    let widthScale = targetScreen.frame.width / displayWidth
    let heightScale = targetScreen.frame.height / displayHeight

    let localX = bounds.origin.x - displayBounds.origin.x
    let localY = bounds.origin.y - displayBounds.origin.y

    let convertedOriginX = targetScreen.frame.origin.x + (localX * widthScale)
    let convertedOriginY = targetScreen.frame.origin.y
        + ((displayBounds.height - (localY + bounds.height)) * heightScale)

    var converted = bounds

    converted.origin.x = convertedOriginX
    converted.origin.y = convertedOriginY
    converted.size.width = bounds.size.width * widthScale
    converted.size.height = bounds.size.height * heightScale

    return converted
}

/// Finds the screen whose frame contains the largest portion of the supplied rect.
private func screenMatching(_ rect: CGRect) -> NSScreen? {
    var bestMatch: (screen: NSScreen, area: CGFloat)?

    for screen in NSScreen.screens {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            continue
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let displayBounds = CGDisplayBounds(displayID)
        let intersection = rect.intersection(displayBounds)
        guard !intersection.isNull else { continue }
        let area = intersection.width * intersection.height
        if let current = bestMatch {
            if area > current.area {
                bestMatch = (screen, area)
            }
        } else {
            bestMatch = (screen, area)
        }
    }

    if let bestMatch {
        return bestMatch.screen
    }

    let center = CGPoint(x: rect.midX, y: rect.midY)
    for screen in NSScreen.screens {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            continue
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        if CGDisplayBounds(displayID).contains(center) {
            return screen
        }
    }

    return NSScreen.main ?? NSScreen.screens.first
}

/// Clamps a corner radius so it never exceeds half the window dimensions.
private func clampCornerRadius(_ radius: CGFloat, to frame: NSRect) -> CGFloat {
    guard radius > 0 else { return 0 }
    let maxRadius = min(frame.width, frame.height) / 2
    return min(radius, maxRadius)
}

/// Provides a conservative default corner radius for macOS versions that hide the value.
private func fallbackCornerRadius(for frame: NSRect) -> CGFloat {
    let minDimension = max(0, min(frame.width, frame.height))
    guard minDimension > 0 else { return 0 }

    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 {
        // macOS Sequoia windows gained a visibly larger radius (approx. 26pt on standard surfaces).
        return min(26, minDimension / 2)
    }

    // Earlier macOS releases keep a consistent ~12pt rounding across standard document windows.
    return min(12, minDimension / 2)
}

/// Determines which process identifier should be preferred when locating the front window.
@MainActor
private func resolvedPreferredProcessIdentifier(_ preferredPID: pid_t?) -> pid_t? {
    if let preferredPID {
        return shouldIgnoreProcessIdentifier(preferredPID) ? nil : preferredPID
    }
    return frontmostApplicationProcessIdentifierForMasking()
}

/// Returns the current frontmost app's PID when it is safe to use for masking.
@MainActor
private func frontmostApplicationProcessIdentifierForMasking() -> pid_t? {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
    if frontmostApp.processIdentifier == ProcessInfo.processInfo.processIdentifier {
        return nil
    }
    if ApplicationMaskingIgnoreList.shared.shouldIgnore(
        bundleIdentifier: frontmostApp.bundleIdentifier,
        processName: frontmostApp.localizedName
    ) {
        return nil
    }
    return frontmostApp.processIdentifier
}

/// Checks whether the frontmost app is currently part of the ignore list.
@MainActor
private func isFrontmostApplicationIgnoredForMasking() -> Bool {
    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return false }
    return ApplicationMaskingIgnoreList.shared.shouldIgnore(
        bundleIdentifier: frontmostApp.bundleIdentifier,
        processName: frontmostApp.localizedName
    )
}

/// Determines whether a process identifier should be ignored entirely.
@MainActor
private func shouldIgnoreProcessIdentifier(_ processID: pid_t) -> Bool {
    guard let application = NSRunningApplication(processIdentifier: processID) else {
        return false
    }
    return ApplicationMaskingIgnoreList.shared.shouldIgnore(
        bundleIdentifier: application.bundleIdentifier,
        processName: application.localizedName
    )
}

/// Resolves whether a specific window should be skipped because its owning application is ignored.
@MainActor
private func shouldIgnoreWindowForMasking(
    pid: pid_t?,
    ownerName: String?,
    windowName: String?,
    bundleIdentifierCache: inout [pid_t: String?]
) -> Bool {
    let identifier: String?
    if let pid {
        identifier = cachedBundleIdentifier(for: pid, cache: &bundleIdentifierCache)
    } else {
        identifier = nil
    }
    return ApplicationMaskingIgnoreList.shared.shouldIgnore(
        bundleIdentifier: identifier,
        processName: ownerName,
        windowName: windowName
    )
}

@MainActor
private func resolveWindowName(
    providedName: String?,
    pid: pid_t?,
    frame: NSRect,
    cornerSnapshotCache: inout [pid_t: [AXWindowCornerSnapshot]]
) -> String? {
    if let pid {
        let snapshots = windowCornerSnapshots(for: pid, cache: &cornerSnapshotCache)
        if let matchedTitle = snapshots
            .first(where: { $0.frame.isApproximatelyEqual(to: frame, tolerance: 3) })?
            .title?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !matchedTitle.isEmpty {
            return matchedTitle
        }
    }

    let trimmedProvided = providedName?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmedProvided, !trimmedProvided.isEmpty {
        return trimmedProvided
    }
    return nil
}

/// Caches bundle identifiers for running processes to avoid repeated lookups.
@MainActor
private func cachedBundleIdentifier(for pid: pid_t, cache: inout [pid_t: String?]) -> String? {
    if let cached = cache[pid] {
        return cached
    }
    let resolvedIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    let normalized = resolvedIdentifier.flatMap { $0.focuslyNormalizedToken() }
    cache[pid] = normalized
    return normalized
}
