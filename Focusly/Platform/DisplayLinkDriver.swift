import AppKit
import CoreVideo

/// Lightweight wrapper around `CVDisplayLink` that forwards ticks to the main actor.
@MainActor
final class DisplayLinkDriver {
    private let tickHandler: () -> Void
    private var displayLink: CVDisplayLink?
    private var isRunning = false

    init(onTick tickHandler: @escaping () -> Void) {
        self.tickHandler = tickHandler
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

        let handlerStatus = CVDisplayLinkSetOutputHandler(resolvedLink) { [weak self] _, _, _, _, _ in
            guard let self else { return kCVReturnSuccess }
            Task { @MainActor in
                self.tickHandler()
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
}
