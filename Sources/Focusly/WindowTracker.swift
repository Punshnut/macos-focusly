import Cocoa

/// Posts updates with the current active window frame and a snapshot of all windows.
/// Polling avoids per-app AX observers and is robust enough for overlays.
final class WindowTracker {
    struct Snapshot {
        let timestamp: Date
        let activeFrame: NSRect?
        let allWindows: [AXWindowInfo]
    }

    static let didUpdate = Notification.Name("Focusly.WindowTracker.didUpdate")
    private var timer: Timer?

    /// Poll interval in seconds (tune for performance vs. responsiveness)
    var interval: TimeInterval = 0.2
    /// Enable when listeners need snapshots of every known window.
    var collectsAllWindows = false

    private let accessCheckInterval: TimeInterval = 1.5
    private var cachedAccessibilityAccess = isAccessibilityAccessGranted()
    private var lastAccessCheck = Date.distantPast

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        refreshAccessibilityStateIfNeeded()
        let hasAccessibility = cachedAccessibilityAccess

        let active: NSRect?
        if hasAccessibility {
            active = resolveActiveWindowFrame()
        } else {
            active = resolveActiveWindowFrameUsingCoreGraphics()
        }

        let all = (hasAccessibility && collectsAllWindows) ? axEnumerateAllWindows() : []
        let snap = Snapshot(timestamp: Date(), activeFrame: active, allWindows: all)
        NotificationCenter.default.post(name: Self.didUpdate, object: snap)
    }

    private func refreshAccessibilityStateIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastAccessCheck) >= accessCheckInterval else { return }
        cachedAccessibilityAccess = isAccessibilityAccessGranted()
        lastAccessCheck = now
    }
}
