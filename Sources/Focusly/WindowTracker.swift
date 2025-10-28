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
        let active = resolveActiveWindowFrame()
        let all = axEnumerateAllWindows()
        let snap = Snapshot(timestamp: Date(), activeFrame: active, allWindows: all)
        NotificationCenter.default.post(name: Self.didUpdate, object: snap)
    }
}
