import Cocoa
@preconcurrency import ApplicationServices

private let axTrustedCheckPromptKey = "AXTrustedCheckOptionPrompt"

@discardableResult
@MainActor
/// Call once on startup to request AX permission (system will show prompt).
func requestAccessibilityIfNeeded(prompt: Bool = true) -> Bool {
    let accessibilityOptions: CFDictionary = [
        axTrustedCheckPromptKey: prompt
    ] as CFDictionary
    return AXIsProcessTrustedWithOptions(accessibilityOptions)
}

/// Returns whether the app currently has accessibility access without showing a prompt.
@MainActor
func isAccessibilityAccessGranted() -> Bool {
    AXIsProcessTrusted()
}

/// Typed window info we expose to the app.
public struct AXWindowInfo: Hashable, Sendable {
    public let pid: pid_t
    public let appName: String
    public let windowTitle: String?
    public let frame: NSRect
    public let isMinimized: Bool
    public let isMain: Bool
    public let isFocused: Bool
}

/// Snapshot of an application's accessibility windows including corner radius metadata.
struct AXWindowCornerSnapshot: Sendable {
    let frame: NSRect
    let cornerRadius: CGFloat?
}

/// Snapshot of the currently focused window including carve-outs for related UI.
public struct ActiveWindowSnapshot: Equatable, Sendable {
    /// Describes a rect that needs to be carved out from the overlay (menus, context menus, etc.).
    public struct MaskRegion: Equatable, Sendable {
        public enum Purpose: Equatable, Sendable {
            case applicationWindow
            case applicationMenu
            case systemMenu
        }

        public let frame: NSRect
        public let cornerRadius: CGFloat
        public let purpose: Purpose
    }

    public let frame: NSRect
    public let cornerRadius: CGFloat
    public let supplementaryMasks: [MaskRegion]

    private static let tolerance: CGFloat = 0.5

    public init(frame: NSRect, cornerRadius: CGFloat, supplementaryMasks: [MaskRegion] = []) {
        self.frame = frame
        self.cornerRadius = cornerRadius
        self.supplementaryMasks = supplementaryMasks
    }

    public static func == (lhs: ActiveWindowSnapshot, rhs: ActiveWindowSnapshot) -> Bool {
        guard lhs.frame.isApproximatelyEqual(to: rhs.frame, tolerance: Self.tolerance) else { return false }
        guard abs(lhs.cornerRadius - rhs.cornerRadius) <= Self.tolerance else { return false }
        guard lhs.supplementaryMasks.count == rhs.supplementaryMasks.count else { return false }

        for (leftMask, rightMask) in zip(lhs.supplementaryMasks, rhs.supplementaryMasks) {
            guard leftMask.purpose == rightMask.purpose else { return false }
            guard leftMask.frame.isApproximatelyEqual(to: rightMask.frame, tolerance: Self.tolerance) else { return false }
            guard abs(leftMask.cornerRadius - rightMask.cornerRadius) <= Self.tolerance else { return false }
        }

        return true
    }
}

private let windowCornerRadiusAttribute = "AXWindowCornerRadius"

/// Decodes a `CGPoint` from a raw accessibility value.
private func axPoint(_ value: CFTypeRef?) -> CGPoint? {
    guard let rawValue = value, CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
    let accessibilityValue = rawValue as! AXValue
    guard AXValueGetType(accessibilityValue) == .cgPoint else { return nil }
    var resolvedPoint = CGPoint.zero
    AXValueGetValue(accessibilityValue, .cgPoint, &resolvedPoint)
    return resolvedPoint
}
/// Decodes a `CGSize` from a raw accessibility value.
private func axSize(_ value: CFTypeRef?) -> CGSize? {
    guard let rawValue = value, CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
    let accessibilityValue = rawValue as! AXValue
    guard AXValueGetType(accessibilityValue) == .cgSize else { return nil }
    var resolvedSize = CGSize.zero
    AXValueGetValue(accessibilityValue, .cgSize, &resolvedSize)
    return resolvedSize
}

/// Active (frontmost) window frame, or nil.
@MainActor
func axActiveWindowFrame(preferredPID: pid_t? = nil) -> NSRect? {
    axActiveWindowSnapshot(preferredPID: preferredPID)?.frame
}

/// Returns the currently focused window description, preferring a given PID if supplied.
@MainActor
func axActiveWindowSnapshot(preferredPID: pid_t? = nil) -> ActiveWindowSnapshot? {
    guard let window = axFocusedWindowElement(preferredPID: preferredPID), let frame = axFrame(for: window) else {
        return nil
    }

    let cornerRadius = axWindowCornerRadius(for: window) ?? 0
    return ActiveWindowSnapshot(frame: frame, cornerRadius: max(0, cornerRadius))
}

/// Resolves the corner radius for the focused window if available.
@MainActor
func axActiveWindowCornerRadius(preferredPID: pid_t? = nil) -> CGFloat? {
    guard let window = axFocusedWindowElement(preferredPID: preferredPID) else { return nil }
    return axWindowCornerRadius(for: window)
}

/// Enumerate windows for all GUI apps (best-effort; requires AX permission).
/// Collects metadata for visible windows across all running GUI apps, capped per process.
@MainActor
func axEnumerateAllWindows(limitPerApp: Int = 200) -> [AXWindowInfo] {
    guard isAccessibilityAccessGranted() else { return [] }

    var collectedWindowInfos: [AXWindowInfo] = []

    for runningApplication in NSWorkspace.shared.runningApplications where runningApplication.activationPolicy != .prohibited {
        let processID = runningApplication.processIdentifier
        let accessibilityApplication = AXUIElementCreateApplication(processID)

        var accessibilityWindowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(accessibilityApplication, kAXWindowsAttribute as CFString, &accessibilityWindowsValue) == .success,
              let accessibilityWindows = accessibilityWindowsValue as? [AXUIElement], !accessibilityWindows.isEmpty else { continue }

        var processedWindowCount = 0
        for windowElement in accessibilityWindows {
            var titleValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleValue)
            let windowTitle = titleValue as? String

            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionValue)
            _ = AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeValue)
            guard let windowPosition = axPoint(positionValue), let windowSize = axSize(sizeValue) else { continue }

            var minimizedValue: CFTypeRef?
            var isMinimized = false
            if AXUIElementCopyAttributeValue(windowElement, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
               let minimizedFlag = minimizedValue as? Bool { isMinimized = minimizedFlag }

            var mainValue: CFTypeRef?
            var isMainWindow = false
            if AXUIElementCopyAttributeValue(windowElement, kAXMainAttribute as CFString, &mainValue) == .success,
               let mainFlag = mainValue as? Bool { isMainWindow = mainFlag }

            var focusedValue: CFTypeRef?
            var isFocusedWindow = false
            if AXUIElementCopyAttributeValue(windowElement, kAXFocusedAttribute as CFString, &focusedValue) == .success,
               let focusedFlag = focusedValue as? Bool { isFocusedWindow = focusedFlag }

            let frame = NSRect(x: windowPosition.x, y: windowPosition.y, width: windowSize.width, height: windowSize.height)
            let info = AXWindowInfo(
                pid: processID,
                appName: runningApplication.localizedName ?? "(unknown)",
                windowTitle: windowTitle,
                frame: frame,
                isMinimized: isMinimized,
                isMain: isMainWindow,
                isFocused: isFocusedWindow && runningApplication.isActive
            )
            collectedWindowInfos.append(info)

            processedWindowCount += 1
            if processedWindowCount >= limitPerApp { break }
        }
    }
    return collectedWindowInfos
}

/// Returns all accessibility windows for the supplied process along with their corner radii.
@MainActor
func axWindowCornerSnapshots(for pid: pid_t) -> [AXWindowCornerSnapshot] {
    guard isAccessibilityAccessGranted() else { return [] }

    let applicationElement = AXUIElementCreateApplication(pid)
    var windowsValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
          let accessibilityWindows = windowsValue as? [AXUIElement],
          !accessibilityWindows.isEmpty else {
        return []
    }

    var snapshots: [AXWindowCornerSnapshot] = []
    snapshots.reserveCapacity(accessibilityWindows.count)

    for windowElement in accessibilityWindows {
        guard let frame = axFrame(for: windowElement) else { continue }
        let radius = axWindowCornerRadius(for: windowElement)
        snapshots.append(AXWindowCornerSnapshot(frame: frame, cornerRadius: radius))
    }

    return snapshots
}

/// Resolves the focused accessibility window element for the requested process or frontmost app.
@MainActor
private func axFocusedWindowElement(preferredPID: pid_t? = nil) -> AXUIElement? {
    guard isAccessibilityAccessGranted() else { return nil }
    let resolvedProcessID: pid_t?
    if let preferredPID {
        resolvedProcessID = preferredPID
    } else {
        resolvedProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    guard let processID = resolvedProcessID else { return nil }
    let accessibilityApplicationElement = AXUIElementCreateApplication(processID)
    var focusedWindowValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(accessibilityApplicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
          let rawFocusedWindow = focusedWindowValue,
          CFGetTypeID(rawFocusedWindow) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeDowncast(rawFocusedWindow as AnyObject, to: AXUIElement.self)
}

/// Extracts the window frame for the supplied accessibility window element.
private func axFrame(for window: AXUIElement) -> NSRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
    AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
    guard let position = axPoint(positionValue), let size = axSize(sizeValue) else { return nil }
    return NSRect(x: position.x, y: position.y, width: size.width, height: size.height)
}

/// Attempts to pull the optional corner radius attribute from a window element.
@MainActor
private func axWindowCornerRadius(for window: AXUIElement) -> CGFloat? {
    var radiusRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, windowCornerRadiusAttribute as CFString, &radiusRef) == .success else {
        return nil
    }
    if let number = radiusRef as? NSNumber {
        return CGFloat(number.doubleValue)
    }
    return nil
}

extension NSRect {
    /// Approximate comparison that tolerates minor rounding differences between coordinate spaces.
    func isApproximatelyEqual(to other: NSRect, tolerance: CGFloat) -> Bool {
        guard tolerance >= 0 else { return self == other }
        return abs(origin.x - other.origin.x) <= tolerance &&
        abs(origin.y - other.origin.y) <= tolerance &&
        abs(size.width - other.size.width) <= tolerance &&
        abs(size.height - other.size.height) <= tolerance
    }
}
