import AppKit
import CoreGraphics
import QuartzCore

/// Captures raw pointer samples using a CoreGraphics event tap so overlay timing can follow
/// high-refresh displays even while the system is animating drag/resize interactions.
@MainActor
final class HighFrequencyPointerSampler {
    typealias Handler = (_ location: NSPoint, _ isDragging: Bool, _ timestamp: CFTimeInterval) -> Void

    private static let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]
        return types.reduce(into: CGEventMask(0)) { partialResult, type in
            partialResult |= (CGEventMask(1) << CGEventMask(type.rawValue))
        }
    }()

    private let handler: Handler
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastSampledLocation: NSPoint?
    private var minimumMovementDistance: CGFloat = 0.35
    private var dragMovementDistance: CGFloat = 0

    init(onSample handler: @escaping Handler) {
        self.handler = handler
    }

    /// Starts the high-frequency event tap if it is not already active.
    func start() {
        guard eventTap == nil else { return }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let sampler = Unmanaged<HighFrequencyPointerSampler>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                return sampler.processEvent(type: type, event: event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Tears down the event tap and run loop plumbing.
    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        lastSampledLocation = nil
    }

    @MainActor
    deinit {
        stop()
    }

    /// Updates the movement threshold the sampler should respect when deciding whether to forward events.
    func updateMinimumMovementDistance(_ distance: CGFloat, dragDistance: CGFloat? = nil) {
        minimumMovementDistance = max(0, distance)
        if let dragDistance {
            dragMovementDistance = max(0, dragDistance)
        }
    }

    private func processEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        default:
            break
        }

        let location = event.location
        let point = NSPoint(x: location.x, y: location.y)
        let isDragging: Bool
        switch type {
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            isDragging = true
        default:
            isDragging = false
        }

        let threshold = isDragging ? dragMovementDistance : minimumMovementDistance
        if threshold > 0, let last = lastSampledLocation {
            let delta = hypot(point.x - last.x, point.y - last.y)
            if delta < threshold {
                return Unmanaged.passUnretained(event)
            }
        }

        lastSampledLocation = point
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handler(point, isDragging, CACurrentMediaTime())
        }
        return Unmanaged.passUnretained(event)
    }
}
