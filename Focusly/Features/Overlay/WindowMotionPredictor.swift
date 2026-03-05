import AppKit
import QuartzCore

/// Tracks recent window geometry deltas and predicts where the next frame will land.
@MainActor
final class WindowMotionPredictor {
    private struct Observation {
        var frame: NSRect
        let timestamp: CFTimeInterval
    }

    private let velocitySmoothingFactor: CGFloat = 0.32
    private let maxTranslationLead: CGFloat = 48
    private let maxSizeLead: CGFloat = 32
    private let significantTranslationThreshold: CGFloat = 0.65
    private let significantSizeThreshold: CGFloat = 0.65
    private let significantVelocityThreshold: CGFloat = 48
    private let significantSizeVelocityThreshold: CGFloat = 22
    private let pointerDeltaAttenuation: CGFloat = 0.9
    private let pointerDeltaMagnitudeCeiling: CGFloat = 64
    private var lastObservation: Observation?
    private var positionVelocity = CGVector(dx: 0, dy: 0)
    private var sizeVelocity = CGSize(width: 0, height: 0)
    private var lastSignificantDeltaTimestamp: CFTimeInterval?

    /// Clears accumulated velocity and history.
    func reset() {
        lastObservation = nil
        positionVelocity = .zero
        sizeVelocity = .zero
        lastSignificantDeltaTimestamp = nil
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

            let translationDelta = hypot(frame.midX - last.frame.midX, frame.midY - last.frame.midY)
            let sizeDelta = max(abs(frame.width - last.frame.width), abs(frame.height - last.frame.height))
            let velocityMagnitude = hypot(positionVelocity.dx, positionVelocity.dy)
            let sizeVelocityMagnitude = max(abs(sizeVelocity.width), abs(sizeVelocity.height))
            if translationDelta > significantTranslationThreshold ||
                sizeDelta > significantSizeThreshold ||
                velocityMagnitude > significantVelocityThreshold ||
                sizeVelocityMagnitude > significantSizeVelocityThreshold {
                lastSignificantDeltaTimestamp = timestamp
            }
        } else {
            positionVelocity = .zero
            sizeVelocity = .zero
            lastSignificantDeltaTimestamp = timestamp
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

    /// Nudges the current observation forward using a pointer delta so prediction stays in sync with drags.
    func applyPointerDelta(_ delta: CGVector, timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard let observation = lastObservation else { return }
        let magnitude = hypot(delta.dx, delta.dy)
        guard magnitude > .ulpOfOne else { return }
        var adjustedFrame = observation.frame
        let dx = clamped(value: delta.dx * pointerDeltaAttenuation, magnitude: pointerDeltaMagnitudeCeiling)
        let dy = clamped(value: delta.dy * pointerDeltaAttenuation, magnitude: pointerDeltaMagnitudeCeiling)
        adjustedFrame.origin.x += dx
        adjustedFrame.origin.y += dy
        record(frame: adjustedFrame, timestamp: timestamp)
    }

    /// Indicates whether a meaningful delta has been observed within the supplied interval.
    func hasRecentSignificantMovement(within interval: TimeInterval, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard interval > 0 else { return true }
        guard let lastTimestamp = lastSignificantDeltaTimestamp else { return false }
        return (now - lastTimestamp) <= interval
    }

    /// Applies exponential smoothing to translational velocity samples.
    private func filteredVelocity(_ current: CGVector, previous: CGVector) -> CGVector {
        let alpha = velocitySmoothingFactor
        let beta = 1 - alpha
        return CGVector(
            dx: (previous.dx * beta) + (current.dx * alpha),
            dy: (previous.dy * beta) + (current.dy * alpha)
        )
    }

    /// Applies exponential smoothing to width/height velocity samples.
    private func filteredSizeVelocity(_ current: CGSize, previous: CGSize) -> CGSize {
        let alpha = velocitySmoothingFactor
        let beta = 1 - alpha
        return CGSize(
            width: (previous.width * beta) + (current.width * alpha),
            height: (previous.height * beta) + (current.height * alpha)
        )
    }

    /// Clamps a scalar value to symmetric +/- magnitude bounds.
    private func clamped(value: CGFloat, magnitude: CGFloat) -> CGFloat {
        guard magnitude > 0 else { return value }
        return min(max(value, -magnitude), magnitude)
    }
}
