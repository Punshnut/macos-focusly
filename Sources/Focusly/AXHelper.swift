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

public struct ActiveWindowSnapshot: Equatable {
    public let frame: NSRect
    public let cornerRadius: CGFloat

    private static let tolerance: CGFloat = 0.5

    public static func == (lhs: ActiveWindowSnapshot, rhs: ActiveWindowSnapshot) -> Bool {
        lhs.frame.isApproximatelyEqual(to: rhs.frame, tolerance: Self.tolerance) &&
        abs(lhs.cornerRadius - rhs.cornerRadius) <= Self.tolerance
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

func axActiveWindowSnapshot(preferredPID: pid_t? = nil) -> ActiveWindowSnapshot? {
    guard let window = axFocusedWindowElement(preferredPID: preferredPID), let frame = axFrame(for: window) else {
        return nil
    }

    let cornerRadius = axWindowCornerRadius(for: window) ?? 0
    return ActiveWindowSnapshot(frame: frame, cornerRadius: max(0, cornerRadius))
}

func axActiveWindowCornerRadius(preferredPID: pid_t? = nil) -> CGFloat? {
    guard let window = axFocusedWindowElement(preferredPID: preferredPID) else { return nil }
    return axWindowCornerRadius(for: window)
}

/// Enumerate windows for all GUI apps (best-effort; requires AX permission).
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

private func axFrame(for window: AXUIElement) -> NSRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
    AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
    guard let p = axPoint(posRef), let s = axSize(sizeRef) else { return nil }
    return NSRect(x: p.x, y: p.y, width: s.width, height: s.height)
}

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
    func isApproximatelyEqual(to other: NSRect, tolerance: CGFloat) -> Bool {
        guard tolerance >= 0 else { return self == other }
        return abs(origin.x - other.origin.x) <= tolerance &&
        abs(origin.y - other.origin.y) <= tolerance &&
        abs(size.width - other.size.width) <= tolerance &&
        abs(size.height - other.size.height) <= tolerance
    }
}
