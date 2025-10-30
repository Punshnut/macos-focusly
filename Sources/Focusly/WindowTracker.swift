import Cocoa

/// Posts updates with the current active window frame and a snapshot of all windows.
/// Polling avoids per-app AX observers and is robust enough for overlays.
final class WindowTracker {
    /// Notification payload describing window state at a particular moment.
    struct Snapshot {
        let timestamp: Date
        let activeFrame: NSRect?
        let allWindows: [AXWindowInfo]
    }

    static let didUpdate = Notification.Name("Focusly.WindowTracker.didUpdate")
    private var pollingTimer: Timer?

    /// Poll interval in seconds (tune for performance vs. responsiveness)
    var pollingInterval: TimeInterval = 0.2
    /// Enable when listeners need snapshots of every known window.
    var isCollectingAllWindows = false

    private let accessibilityCheckInterval: TimeInterval = 1.5
    private var hasAccessibilityPermission = isAccessibilityAccessGranted()
    private var lastAccessibilityCheck = Date.distantPast

    /// Begins polling for active window changes and posts notifications.
    func start() {
        stop()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            self?.handleTimerTick()
        }
        guard let pollingTimer else { return }
        RunLoop.main.add(pollingTimer, forMode: .common)
    }

    /// Stops polling and releases the timer.
    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    /// Collects the latest window metadata and publishes it to observers.
    private func handleTimerTick() {
        refreshAccessibilityPermissionIfNeeded()
        let isAccessibilityAuthorized = hasAccessibilityPermission

        let activeWindowFrame: NSRect?
        if isAccessibilityAuthorized {
            activeWindowFrame = resolveActiveWindowFrame()
        } else {
            activeWindowFrame = resolveActiveWindowFrameUsingCoreGraphics()
        }

        let enumeratedWindows = (isAccessibilityAuthorized && isCollectingAllWindows) ? axEnumerateAllWindows() : []
        let snapshot = Snapshot(timestamp: Date(), activeFrame: activeWindowFrame, allWindows: enumeratedWindows)
        NotificationCenter.default.post(name: Self.didUpdate, object: snapshot)
    }

    /// Periodically re-checks accessibility permission so we can downgrade gracefully if revoked.
    private func refreshAccessibilityPermissionIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastAccessibilityCheck) >= accessibilityCheckInterval else { return }
        hasAccessibilityPermission = isAccessibilityAccessGranted()
        lastAccessibilityCheck = now
    }
}
