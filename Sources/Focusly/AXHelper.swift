import Cocoa
import ApplicationServices

/// Call once on startup to request AX permission (system will show prompt).
@discardableResult
func requestAccessibilityIfNeeded(prompt: Bool = true) -> Bool {
    let opts: CFDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(opts)
}

/// Returns whether the app currently has accessibility access without showing a prompt.
func isAccessibilityAccessGranted() -> Bool {
    AXIsProcessTrusted()
}

/// Typed window info we expose to the app.
public struct AXWindowInfo: Hashable {
    public let pid: pid_t
    public let appName: String
    public let windowTitle: String?
    public let frame: NSRect
    public let isMinimized: Bool
    public let isMain: Bool
    public let isFocused: Bool
}

/// Snapshot of the currently focused window including carve-outs for related UI.
public struct ActiveWindowSnapshot: Equatable {
    /// Describes a rect that needs to be carved out from the overlay (menus, context menus, etc.).
    public struct MaskRegion: Equatable {
        public enum Purpose: Equatable {
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

private let windowCornerRadiusAttribute: CFString = "AXWindowCornerRadius" as CFString

private func axPoint(_ value: CFTypeRef?) -> CGPoint? {
    guard let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let axValue = raw as! AXValue
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var p = CGPoint.zero
    AXValueGetValue(axValue, .cgPoint, &p)
    return p
}
private func axSize(_ value: CFTypeRef?) -> CGSize? {
    guard let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let axValue = raw as! AXValue
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var s = CGSize.zero
    AXValueGetValue(axValue, .cgSize, &s)
    return s
}

/// Active (frontmost) window frame, or nil.
func axActiveWindowFrame(preferredPID: pid_t? = nil) -> NSRect? {
    axActiveWindowSnapshot(preferredPID: preferredPID)?.frame
}

/// Returns the currently focused window description, preferring a given PID if supplied.
func axActiveWindowSnapshot(preferredPID: pid_t? = nil) -> ActiveWindowSnapshot? {
    guard let window = axFocusedWindowElement(preferredPID: preferredPID), let frame = axFrame(for: window) else {
        return nil
    }

    let cornerRadius = axWindowCornerRadius(for: window) ?? 0
    return ActiveWindowSnapshot(frame: frame, cornerRadius: max(0, cornerRadius))
}

/// Resolves the corner radius for the focused window if available.
func axActiveWindowCornerRadius(preferredPID: pid_t? = nil) -> CGFloat? {
    guard let window = axFocusedWindowElement(preferredPID: preferredPID) else { return nil }
    return axWindowCornerRadius(for: window)
}

/// Enumerate windows for all GUI apps (best-effort; requires AX permission).
/// Collects metadata for visible windows across all running GUI apps, capped per process.
func axEnumerateAllWindows(limitPerApp: Int = 200) -> [AXWindowInfo] {
    guard isAccessibilityAccessGranted() else { return [] }

    var all: [AXWindowInfo] = []

    for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else { continue }

        var count = 0
        for w in windows {
            var titleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String

            var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef)
            _ = AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef)
            guard let p = axPoint(posRef), let s = axSize(sizeRef) else { continue }

            var minimizedRef: CFTypeRef?; var isMin = false
            if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
               let b = minimizedRef as? Bool { isMin = b }

            var mainRef: CFTypeRef?; var isMain = false
            if AXUIElementCopyAttributeValue(w, kAXMainAttribute as CFString, &mainRef) == .success,
               let b = mainRef as? Bool { isMain = b }

            var focusedRef: CFTypeRef?; var isFocused = false
            if AXUIElementCopyAttributeValue(w, kAXFocusedAttribute as CFString, &focusedRef) == .success,
               let b = focusedRef as? Bool { isFocused = b }

            let frame = NSRect(x: p.x, y: p.y, width: s.width, height: s.height)
            let info = AXWindowInfo(
                pid: pid,
                appName: app.localizedName ?? "(unknown)",
                windowTitle: title,
                frame: frame,
                isMinimized: isMin,
                isMain: isMain,
                isFocused: isFocused && app.isActive
            )
            all.append(info)

            count += 1
            if count >= limitPerApp { break }
        }
    }
    return all
}

/// Returns the focused `AXUIElement` for the chosen process or the active application.
private func axFocusedWindowElement(preferredPID: pid_t? = nil) -> AXUIElement? {
    guard isAccessibilityAccessGranted() else { return nil }
    let resolvedPID: pid_t?
    if let preferredPID {
        resolvedPID = preferredPID
    } else {
        resolvedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    guard let pid = resolvedPID else { return nil }
    let axApp = AXUIElementCreateApplication(pid)
    var winRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
          let rawWin = winRef,
          CFGetTypeID(rawWin) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeBitCast(rawWin, to: AXUIElement.self)
}

/// Extracts an AppKit-style rect from the accessibility window element.
private func axFrame(for window: AXUIElement) -> NSRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
    AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
    guard let p = axPoint(posRef), let s = axSize(sizeRef) else { return nil }
    return NSRect(x: p.x, y: p.y, width: s.width, height: s.height)
}

/// Attempts to pull the optional corner radius attribute from a window element.
private func axWindowCornerRadius(for window: AXUIElement) -> CGFloat? {
    var radiusRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, windowCornerRadiusAttribute, &radiusRef) == .success else {
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
