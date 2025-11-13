import AppKit
import CoreGraphics
import CoreVideo

/// Timing metadata delivered with each display-link callback so downstream consumers
/// can pace their work to the host display's refresh cadence.
struct DisplayLinkFrameTiming {
    let hostTime: UInt64
    let refreshPeriod: TimeInterval
}

/// Lightweight wrapper around `CVDisplayLink` that forwards ticks to the main actor.
@MainActor
final class DisplayLinkDriver {
    private let tickHandler: (DisplayLinkFrameTiming) -> Void
    private var displayLink: CVDisplayLink?
    private var isRunning = false
    private var preferredDisplayID: DisplayID?
    private var latestRefreshPeriod: TimeInterval = 1.0 / 60.0

    init(onTick tickHandler: @escaping (DisplayLinkFrameTiming) -> Void) {
        self.tickHandler = tickHandler
    }

    /// Updates the preferred display identifier so the driver can follow high-refresh-rate panels.
    func setPreferredDisplayID(_ displayID: DisplayID?) {
        preferredDisplayID = displayID
        guard let link = displayLink else { return }
        applyPreferredDisplayID(to: link)
    }

    /// Starts the display link if it is not already active.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        var link: CVDisplayLink?
        let creationResult = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard creationResult == kCVReturnSuccess, let resolvedLink = link else {
            return false
        }

        applyPreferredDisplayID(to: resolvedLink)

        let handlerStatus = CVDisplayLinkSetOutputHandler(resolvedLink) { [weak self] link, _, outputTime, _, _ in
            guard let self else { return kCVReturnSuccess }
            let output = outputTime.pointee
            let candidatePeriod = DisplayLinkDriver.extractRefreshPeriod(link: link, outputTime: output)
            Task { @MainActor in
                let refreshPeriod = self.resolveRefreshPeriod(candidatePeriod: candidatePeriod, outputTime: output)
                let timing = DisplayLinkFrameTiming(hostTime: output.hostTime, refreshPeriod: refreshPeriod)
                self.tickHandler(timing)
            }
            return kCVReturnSuccess
        }

        guard handlerStatus == kCVReturnSuccess else {
            CVDisplayLinkStop(resolvedLink)
            displayLink = nil
            return false
        }

        CVDisplayLinkStart(resolvedLink)
        displayLink = resolvedLink
        isRunning = true
        return true
    }

    /// Stops the display link if it is running.
    func stop() {
        guard isRunning else { return }
        guard let link = displayLink else {
            isRunning = false
            return
        }
        CVDisplayLinkStop(link)
        CVDisplayLinkSetOutputHandler(link, { _, _, _, _, _ in kCVReturnSuccess })
        displayLink = nil
        isRunning = false
    }

    @MainActor
    deinit {
        if isRunning, let link = displayLink {
            CVDisplayLinkStop(link)
            CVDisplayLinkSetOutputHandler(link, { _, _, _, _, _ in kCVReturnSuccess })
        }
        displayLink = nil
        isRunning = false
    }

    /// Applies the currently preferred display identifier to the supplied link.
    private func applyPreferredDisplayID(to link: CVDisplayLink) {
        let targetID = preferredDisplayID ?? DisplayID(CGMainDisplayID())
        CVDisplayLinkSetCurrentCGDisplay(link, CGDirectDisplayID(targetID))
    }

    /// Returns the freshest known refresh period, falling back to the previous value when needed.
    private func resolveRefreshPeriod(candidatePeriod: TimeInterval?, outputTime: CVTimeStamp) -> TimeInterval {
        if let candidate = candidatePeriod, candidate.isFinite, candidate > 0 {
            latestRefreshPeriod = candidate
            return candidate
        }

        let refreshPeriod = outputTime.videoRefreshPeriod
        let timeScale = outputTime.videoTimeScale
        if refreshPeriod > 0, timeScale > 0 {
            let period = TimeInterval(refreshPeriod) / TimeInterval(timeScale)
            latestRefreshPeriod = period
            return period
        }

        return latestRefreshPeriod
    }

    /// Calculates the most precise refresh period available without touching actor state.
    private nonisolated static func extractRefreshPeriod(link: CVDisplayLink, outputTime: CVTimeStamp) -> TimeInterval? {
        let reportedPeriod = CVDisplayLinkGetActualOutputVideoRefreshPeriod(link)
        if reportedPeriod.isFinite, reportedPeriod > 0 {
            return reportedPeriod
        }

        let refreshPeriod = outputTime.videoRefreshPeriod
        let timeScale = outputTime.videoTimeScale
        guard refreshPeriod > 0, timeScale > 0 else { return nil }
        return TimeInterval(refreshPeriod) / TimeInterval(timeScale)
    }
}
