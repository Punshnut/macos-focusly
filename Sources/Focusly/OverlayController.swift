// Permissions (TCC):
// - Accessibility: required to retrieve focused window frames.
// - App Store: feature category "system-wide overlays" is often review-sensitive.

import AppKit

/// Keeps OverlayWindow instances synchronized with the focused window and display configuration.
@MainActor
final class OverlayController {
    private struct PollingCadence {
        let idleInterval: TimeInterval
        let interactionInterval: TimeInterval

        init(profile: WindowTrackingProfile) {
            self.idleInterval = profile.idleInterval
            self.interactionInterval = profile.interactionInterval
        }
    }

    private struct MaskRequest {
        let rect: NSRect
        let cornerRadius: CGFloat
        let purpose: ActiveWindowSnapshot.MaskRegion.Purpose?
    }

    private let interactionBoostDuration: TimeInterval = 0.6
    private let interactionCooldownDuration: TimeInterval = 0.25
    private let supplementalSnapshotInterval: TimeInterval = 1.0 / 15.0
    private let activeWindowSnapshotResolver: (Set<Int>) -> ActiveWindowSnapshot?

    private var overlayWindows: [DisplayID: OverlayWindow] = [:]
    private var pollingTimer: Timer?
    private var trackingProfile: WindowTrackingProfile
    private var pollingCadence: PollingCadence
    private var currentPollingInterval: TimeInterval
    private var interactionDeadline: Date?
    private var isClickThroughEnabled = true
    private var isRunning = false
    private var cachedActiveWindowSnapshot: ActiveWindowSnapshot?
    private var pointerInteractionMonitor: PointerInteractionMonitor?
    private lazy var displayLinkDriver = DisplayLinkDriver { [weak self] in
        guard let self else { return }
        self.handleDisplayLinkTick()
    }
    private var isDisplayLinkRunning = false

    init(
        activeWindowSnapshotResolver: @escaping (Set<Int>) -> ActiveWindowSnapshot? = { windowNumbers in
            resolveActiveWindowSnapshot(excluding: windowNumbers)
        }
    ) {
        self.activeWindowSnapshotResolver = activeWindowSnapshotResolver
        self.trackingProfile = .standard
        self.pollingCadence = PollingCadence(profile: .standard)
        self.currentPollingInterval = pollingCadence.idleInterval
    }

    /// Begins monitoring the focused window and updates overlay masks accordingly.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        configurePointerInteractionMonitoring()
        startPolling()
        applyCachedOverlayMask()
        if cachedActiveWindowSnapshot == nil {
            refreshActiveWindowSnapshot()
        }
    }

    /// Stops monitoring and clears active overlay carve-outs.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopPolling()
        stopPointerInteractionMonitoring()
        stopDisplayLinkIfNeeded()
        cachedActiveWindowSnapshot = nil
        overlayWindows.values.forEach { $0.applyMask(regions: []) }
    }

    /// Toggles whether overlay windows forward mouse events to windows underneath.
    func setClickThrough(_ enabled: Bool) {
        isClickThroughEnabled = enabled
        overlayWindows.values.forEach { $0.setClickThrough(enabled) }
    }

    /// Updates the polling cadence to match the selected tracking profile.
    func updateTrackingProfile(_ profile: WindowTrackingProfile) {
        guard trackingProfile != profile else { return }
        trackingProfile = profile
        pollingCadence = PollingCadence(profile: profile)
        let targetInterval = desiredIntervalForCurrentInteractionState()
        currentPollingInterval = targetInterval
        if isRunning {
            schedulePollingTimer(with: targetInterval)
        }
    }

    /// Seeds the controller with an initial snapshot so overlays can immediately carve it out.
    func primeOverlayMask(with snapshot: ActiveWindowSnapshot?) {
        cachedActiveWindowSnapshot = snapshot
        if isRunning {
            applyCachedOverlayMask()
        }
    }

    /// Replaces the overlay window map, cleaning up removed displays and applying cached masks.
    func refreshOverlayWindows(_ updatedOverlayWindows: [DisplayID: OverlayWindow]) {
        let previousOverlayWindows = overlayWindows
        overlayWindows = updatedOverlayWindows

        let removedDisplayIDs = Set(previousOverlayWindows.keys).subtracting(updatedOverlayWindows.keys)
        for displayID in removedDisplayIDs {
            previousOverlayWindows[displayID]?.applyMask(regions: [])
        }

        overlayWindows.values.forEach { $0.setClickThrough(isClickThroughEnabled) }

        if isRunning {
            applyCachedOverlayMask()
        }
    }

    /// Applies the supplied snapshot to all overlays, carving out the focused window and related UI.
    func applyOverlayMask(with snapshot: ActiveWindowSnapshot?) {
        guard let snapshot else {
            // Keep showing the last snapshot if the resolver temporarily fails so the focused window stays clear.
            guard cachedActiveWindowSnapshot == nil else { return }
            overlayWindows.values.forEach { $0.applyMask(regions: []) }
            return
        }

        cachedActiveWindowSnapshot = snapshot

        let activeFrame = snapshot.frame
        var maskRequests: [MaskRequest] = [
            MaskRequest(
                rect: activeFrame,
                cornerRadius: snapshot.cornerRadius,
                purpose: .applicationWindow
            )
        ]

        if !snapshot.supplementaryMasks.isEmpty {
            maskRequests.append(contentsOf: snapshot.supplementaryMasks.map {
                MaskRequest(rect: $0.frame, cornerRadius: $0.cornerRadius, purpose: $0.purpose)
            })
        }

        var didApplyMask = false

        for (_, window) in overlayWindows {
            guard let contentView = window.contentView else {
                window.applyMask(regions: [])
                continue
            }

            let windowScreenFrame = window.frame
            var maskRegions: [OverlayWindow.MaskRegion] = []

            for request in maskRequests {
                let expansion = maskExpansion(for: request.purpose)
                let expandedRect: NSRect
                if expansion > 0 {
                    expandedRect = request.rect.insetBy(dx: -expansion, dy: -expansion)
                } else {
                    expandedRect = request.rect
                }

                let screenIntersection = expandedRect.intersection(windowScreenFrame)
                guard !screenIntersection.isNull else { continue }

                let windowRect = window.convertFromScreen(screenIntersection)
                let rectInContent = contentView.convert(windowRect, from: nil)
                let normalizedRect = rectInContent.intersection(contentView.bounds)
                guard !normalizedRect.isNull else { continue }

                maskRegions.append(
                    OverlayWindow.MaskRegion(
                        rect: normalizedRect,
                        cornerRadius: adjustedCornerRadius(for: request, expansion: expansion)
                    )
                )
            }

            if maskRegions.isEmpty {
                window.applyMask(regions: [])
            } else {
                window.applyMask(regions: maskRegions)
                didApplyMask = true
            }
        }

        if !didApplyMask {
            overlayWindows.values.forEach { $0.applyMask(regions: []) }
        }
    }

    /// Starts a repeating timer that samples the focused window position.
    private func startPolling() {
        schedulePollingTimer(with: currentPollingInterval)
    }

    /// Stops the polling timer.
    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        currentPollingInterval = pollingCadence.idleInterval
    }

    /// Reapplies the last known snapshot so new overlay windows pick up current carve-outs.
    private func applyCachedOverlayMask() {
        applyOverlayMask(with: cachedActiveWindowSnapshot)
    }

    /// Resolves the active window snapshot and updates overlays when it changes.
    @discardableResult
    private func refreshActiveWindowSnapshot() -> Bool {
        let snapshot = activeWindowSnapshotResolver(activeOverlayWindowNumbers())
        let previousSnapshot = cachedActiveWindowSnapshot

        switch (previousSnapshot, snapshot) {
        case (nil, nil):
            return false
        case let (previous?, current?):
            guard previous != current else { return false }
        default:
            break
        }

        applyOverlayMask(with: snapshot)
        return true
    }

    /// Returns window numbers for overlays so they can be ignored when calculating focus.
    private func activeOverlayWindowNumbers() -> Set<Int> {
        Set(
            overlayWindows.values
                .map { $0.windowNumber }
                .filter { $0 != 0 }
        )
    }

    /// Timer callback that re-checks the focused window position.
    @objc private func handlePollingTimer(_ timer: Timer) {
        let didChange = refreshActiveWindowSnapshot()
        if didChange {
            enterInteractionBoost(minimumDuration: interactionBoostDuration)
        }
        evaluateInteractionDeadline()
    }

    /// Determines how much a given mask should expand to cover drop-shadows and hover states.
    private func maskExpansion(for purpose: ActiveWindowSnapshot.MaskRegion.Purpose?) -> CGFloat {
        switch purpose {
        case .applicationMenu?, .systemMenu?:
            return 4
        case .applicationWindow?:
            return 1
        case nil:
            return 1
        }
    }

    /// Adjusts the corner radius to match the expanded mask rect.
    private func adjustedCornerRadius(for request: MaskRequest, expansion: CGFloat) -> CGFloat {
        let baseRadius = max(0, request.cornerRadius)
        guard expansion > 0 else { return baseRadius }
        return baseRadius + expansion
    }

    /// Creates and starts a pointer monitor so we can react to drag and resize interactions.
    private func configurePointerInteractionMonitoring() {
        if pointerInteractionMonitor == nil {
            pointerInteractionMonitor = PointerInteractionMonitor { [weak self] state in
                guard let self else { return }
                switch state {
                case .began, .dragged:
                    self.enterInteractionBoost(minimumDuration: self.interactionBoostDuration)
                case .ended:
                    self.enterInteractionBoost(minimumDuration: self.interactionCooldownDuration)
                }
            }
        }
        pointerInteractionMonitor?.start()
    }

    /// Tears down the pointer monitor when overlays are inactive.
    private func stopPointerInteractionMonitoring() {
        pointerInteractionMonitor?.stop()
        pointerInteractionMonitor = nil
        interactionDeadline = nil
        stopDisplayLinkIfNeeded()
    }

    /// Resets and schedules the polling timer with a new interval.
    private func schedulePollingTimer(with interval: TimeInterval) {
        guard interval > 0 else { return }
        pollingTimer?.invalidate()
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(handlePollingTimer(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer
        currentPollingInterval = interval
    }

    /// Ensures the timer interval matches the requested cadence.
    private func updatePollingIntervalIfNeeded(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        if abs(currentPollingInterval - interval) <= 0.0005, pollingTimer != nil {
            return
        }
        schedulePollingTimer(with: interval)
    }

    /// Resolves the desired interval based on whether a pointer interaction boost is active.
    private func desiredIntervalForCurrentInteractionState() -> TimeInterval {
        if let deadline = interactionDeadline, Date() < deadline {
            if isDisplayLinkRunning {
                return max(pollingCadence.interactionInterval, supplementalSnapshotInterval)
            }
            return pollingCadence.interactionInterval
        }
        return pollingCadence.idleInterval
    }

    /// Keeps the high-frequency polling window alive while interactions are active.
    private func enterInteractionBoost(minimumDuration: TimeInterval) {
        guard minimumDuration > 0 else { return }
        let proposedDeadline = Date().addingTimeInterval(minimumDuration)
        if let currentDeadline = interactionDeadline {
            interactionDeadline = max(currentDeadline, proposedDeadline)
        } else {
            interactionDeadline = proposedDeadline
        }
        updatePollingIntervalIfNeeded(pollingCadence.interactionInterval)
        startDisplayLinkIfNeeded()
    }

    /// Switches back to the idle cadence when interactions have settled for long enough.
    private func evaluateInteractionDeadline() {
        guard let deadline = interactionDeadline else {
            if currentPollingInterval != pollingCadence.idleInterval {
                updatePollingIntervalIfNeeded(pollingCadence.idleInterval)
            }
            return
        }

        if Date() >= deadline {
            interactionDeadline = nil
            updatePollingIntervalIfNeeded(pollingCadence.idleInterval)
            stopDisplayLinkIfNeeded()
        } else {
            updatePollingIntervalIfNeeded(pollingCadence.interactionInterval)
        }
    }

    private func startDisplayLinkIfNeeded() {
        guard !isDisplayLinkRunning else { return }
        if displayLinkDriver.start() {
            isDisplayLinkRunning = true
        }
    }

    private func stopDisplayLinkIfNeeded() {
        guard isDisplayLinkRunning else { return }
        displayLinkDriver.stop()
        isDisplayLinkRunning = false
    }

    private func handleDisplayLinkTick() {
        guard isRunning else { return }
        switch refreshActiveWindowFrameFast() {
        case .updated, .noChange:
            break
        case .needsFallback:
            _ = refreshActiveWindowSnapshot()
        }
        evaluateInteractionDeadline()
    }

    private enum FrameRefreshResult {
        case updated
        case noChange
        case needsFallback
    }

    /// Attempts a lightweight position refresh using the CoreGraphics frame list to avoid
    /// reconstructing supplementary mask metadata on every display refresh.
    private func refreshActiveWindowFrameFast() -> FrameRefreshResult {
        let exclusionNumbers = activeOverlayWindowNumbers()
        guard let cgFrame = resolveActiveWindowFrameUsingCoreGraphics(excluding: exclusionNumbers) else {
            return .needsFallback
        }

        if var cachedSnapshot = cachedActiveWindowSnapshot {
            let tolerance: CGFloat = 0.35
            if cachedSnapshot.frame.isApproximatelyEqual(to: cgFrame, tolerance: tolerance) {
                return .noChange
            }

            cachedSnapshot = ActiveWindowSnapshot(
                frame: cgFrame,
                cornerRadius: cachedSnapshot.cornerRadius,
                supplementaryMasks: cachedSnapshot.supplementaryMasks
            )
            cachedActiveWindowSnapshot = cachedSnapshot
            applyOverlayMask(with: cachedSnapshot)
            return .updated
        }

        return .needsFallback
    }
}

extension OverlayController: OverlayServiceDelegate {
    /// Receives overlay updates from the service and replaces the managed window set.
    func overlayService(_ service: OverlayService, didUpdateOverlays updatedOverlayWindows: [DisplayID: OverlayWindow]) {
        refreshOverlayWindows(updatedOverlayWindows)
    }
}
