import AppKit

/// Lightweight monitor that emits global pointer location changes for hover-driven affordances.
@MainActor
final class PointerHoverMonitor {
    private let handler: (NSPoint) -> Void
    private var monitorToken: Any?
    private var lastEmittedLocation: NSPoint?
    private let minimumMovementDistance: CGFloat = 0.75

    init(onLocationChanged handler: @escaping (NSPoint) -> Void) {
        self.handler = handler
    }

    /// Begins listening for global mouse move/enter/exit events.
    func start() {
        guard monitorToken == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .mouseEntered, .mouseExited]
        monitorToken = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event: event)
            }
        }
    }

    /// Stops listening for global pointer movement.
    func stop() {
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
        lastEmittedLocation = nil
    }

    private func handle(event: NSEvent) {
        let location = event.locationInWindow
        if let last = lastEmittedLocation {
            let deltaX = last.x - location.x
            let deltaY = last.y - location.y
            if hypot(deltaX, deltaY) < minimumMovementDistance {
                return
            }
        }
        lastEmittedLocation = location
        handler(location)
    }
}
