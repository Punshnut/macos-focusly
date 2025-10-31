import AppKit

/// Tracks global pointer interactions so overlay updates can temporarily run at a higher cadence.
@MainActor
final class PointerInteractionMonitor {
    enum State {
        case began
        case dragged
        case ended
    }

    private let handler: (State) -> Void
    private var globalMonitor: Any?
    private var isPointerDown = false

    init(onStateChanged handler: @escaping (State) -> Void) {
        self.handler = handler
    }

    /// Begins listening for pointer events across the system.
    func start() {
        guard globalMonitor == nil else { return }
        let monitoredEvents: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged
        ]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: monitoredEvents) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event: event)
            }
        }
    }

    /// Stops listening for pointer events.
    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        isPointerDown = false
    }

    private func handle(event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if !isPointerDown {
                isPointerDown = true
                handler(.began)
            }
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if !isPointerDown {
                isPointerDown = true
                handler(.began)
            }
            handler(.dragged)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if isPointerDown {
                isPointerDown = false
                handler(.ended)
            }
        default:
            break
        }
    }
}
