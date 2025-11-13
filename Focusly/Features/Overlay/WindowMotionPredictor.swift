import AppKit
import QuartzCore

/// Tracks recent window geometry deltas and predicts where the next frame will land.
@MainActor
final class WindowMotionPredictor {
    private struct Observation {
        var frame: NSRect
        let timestamp: CFTimeInterval
    }

    private let velocitySmoothingFactor: CGFloat = 0.42
    private let maxTranslationLead: CGFloat = 72
    private let maxSizeLead: CGFloat = 48
    private var lastObservation: Observation?
    private var positionVelocity = CGVector(dx: 0, dy: 0)
    private var sizeVelocity = CGSize(width: 0, height: 0)

    /// Clears accumulated velocity and history.
    func reset() {
        lastObservation = nil
        positionVelocity = .zero
        sizeVelocity = .zero
    }

    /// Records the latest resolved frame so velocities can be updated.
    func record(frame: NSRect, timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard frame.width > 0, frame.height > 0 else {
            reset()
            return
        }

        if let last = lastObservation {
            let deltaTime = max(timestamp - last.timestamp, 1.0 / 1000.0)
            let currentVelocity = CGVector(
                dx: (frame.midX - last.frame.midX) / deltaTime,
                dy: (frame.midY - last.frame.midY) / deltaTime
            )
            let currentSizeVelocity = CGSize(
                width: (frame.width - last.frame.width) / deltaTime,
                height: (frame.height - last.frame.height) / deltaTime
            )
            positionVelocity = filteredVelocity(currentVelocity, previous: positionVelocity)
            sizeVelocity = filteredSizeVelocity(currentSizeVelocity, previous: sizeVelocity)
        } else {
            positionVelocity = .zero
            sizeVelocity = .zero
        }

        lastObservation = Observation(frame: frame, timestamp: timestamp)
    }

    /// Predicts a frame `leadTime` seconds in the future using the smoothed velocities.
    func predictedFrame(leadTime: TimeInterval) -> NSRect? {
        guard var observation = lastObservation else { return nil }
        guard leadTime > 0 else { return observation.frame }

        let leadDuration = CGFloat(leadTime)
        let clampedDX = clamped(value: positionVelocity.dx * leadDuration, magnitude: maxTranslationLead)
        let clampedDY = clamped(value: positionVelocity.dy * leadDuration, magnitude: maxTranslationLead)
        let clampedDW = clamped(value: sizeVelocity.width * leadDuration, magnitude: maxSizeLead)
        let clampedDH = clamped(value: sizeVelocity.height * leadDuration, magnitude: maxSizeLead)

        observation.frame.origin.x += clampedDX
        observation.frame.origin.y += clampedDY
        observation.frame.size.width = max(4, observation.frame.width + clampedDW)
        observation.frame.size.height = max(4, observation.frame.height + clampedDH)
        return observation.frame
    }

    private func filteredVelocity(_ current: CGVector, previous: CGVector) -> CGVector {
        let alpha = velocitySmoothingFactor
        let beta = 1 - alpha
        return CGVector(
            dx: (previous.dx * beta) + (current.dx * alpha),
            dy: (previous.dy * beta) + (current.dy * alpha)
        )
    }

    private func filteredSizeVelocity(_ current: CGSize, previous: CGSize) -> CGSize {
        let alpha = velocitySmoothingFactor
        let beta = 1 - alpha
        return CGSize(
            width: (previous.width * beta) + (current.width * alpha),
            height: (previous.height * beta) + (current.height * alpha)
        )
    }

    private func clamped(value: CGFloat, magnitude: CGFloat) -> CGFloat {
        guard magnitude > 0 else { return value }
        return min(max(value, -magnitude), magnitude)
    }
}
