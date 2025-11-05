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

    private var overlayWindowsByDisplay: [DisplayID: OverlayWindow] = [:]
    private var snapshotPollingTimer: Timer?
    private var activeTrackingProfile: WindowTrackingProfile
    private var activePollingCadence: PollingCadence
    private var resolvedPollingInterval: TimeInterval
    private var interactionBoostDeadline: Date?
    private var isClickThroughModeEnabled = true
    private var isMonitoring = false
    private var cachedActiveSnapshot: ActiveWindowSnapshot?
    private var cachedSnapshotsByDisplay: [DisplayID: ActiveWindowSnapshot] = [:]
    private var currentActiveDisplayID: DisplayID?
    private var pointerMonitor: PointerInteractionMonitor?
    private lazy var supplementalDisplayLink = DisplayLinkDriver { [weak self] in
        guard let self else { return }
        self.handleDisplayLinkTick()
    }
    private var isDisplayLinkActive = false

    init(
        activeWindowSnapshotResolver: @escaping (Set<Int>) -> ActiveWindowSnapshot? = { windowNumbers in
            resolveActiveWindowSnapshot(excluding: windowNumbers)
        }
    ) {
        self.activeWindowSnapshotResolver = activeWindowSnapshotResolver
        self.activeTrackingProfile = .standard
        self.activePollingCadence = PollingCadence(profile: .standard)
        self.resolvedPollingInterval = activePollingCadence.idleInterval
    }

    /// Begins monitoring the focused window and updates overlay masks accordingly.
    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        configurePointerInteractionMonitoring()
        startPolling()
        applyCachedOverlayMask()
        if cachedActiveSnapshot == nil {
            refreshActiveWindowSnapshot()
        }
    }

    /// Stops monitoring and clears active overlay carve-outs.
    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        stopPolling()
        stopPointerInteractionMonitoring()
        stopDisplayLinkIfNeeded()
        cachedActiveSnapshot = nil
        cachedSnapshotsByDisplay.removeAll()
        currentActiveDisplayID = nil
        overlayWindowsByDisplay.values.forEach { $0.applyMask(regions: []) }
    }

    /// Toggles whether overlay windows forward mouse events to windows underneath.
    func setClickThrough(_ enabled: Bool) {
        isClickThroughModeEnabled = enabled
        overlayWindowsByDisplay.values.forEach { $0.setClickThrough(enabled) }
    }

    /// Updates the polling cadence to match the selected tracking profile.
    func updateTrackingProfile(_ profile: WindowTrackingProfile) {
        guard activeTrackingProfile != profile else { return }
        activeTrackingProfile = profile
        activePollingCadence = PollingCadence(profile: profile)
        let targetInterval = desiredIntervalForCurrentInteractionState()
        resolvedPollingInterval = targetInterval
        if isMonitoring {
            schedulePollingTimer(with: targetInterval)
        }
    }

    /// Seeds the controller with an initial snapshot so overlays can immediately carve it out.
    func primeOverlayMask(with snapshot: ActiveWindowSnapshot?) {
        if let snapshot {
            cacheActiveSnapshot(snapshot)
        } else {
            cachedActiveSnapshot = nil
            cachedSnapshotsByDisplay.removeAll()
            currentActiveDisplayID = nil
        }
        if isMonitoring {
            applyCachedOverlayMask()
        }
    }

    /// Replaces the overlay window map, cleaning up removed displays and applying cached masks.
    func refreshOverlayWindows(_ updatedOverlayWindows: [DisplayID: OverlayWindow]) {
        let previousOverlayWindows = overlayWindowsByDisplay
        overlayWindowsByDisplay = updatedOverlayWindows

        let removedDisplayIDs = Set(previousOverlayWindows.keys).subtracting(updatedOverlayWindows.keys)
        for displayID in removedDisplayIDs {
            previousOverlayWindows[displayID]?.applyMask(regions: [])
        }

        let updatedDisplayIDs = Set(updatedOverlayWindows.keys)
        cachedSnapshotsByDisplay = cachedSnapshotsByDisplay.filter { updatedDisplayIDs.contains($0.key) }
        if let activeID = currentActiveDisplayID, !updatedDisplayIDs.contains(activeID) {
            currentActiveDisplayID = nil
        }

        overlayWindowsByDisplay.values.forEach { $0.setClickThrough(isClickThroughModeEnabled) }

        if isMonitoring {
            applyCachedOverlayMask()
        }
    }

    /// Applies the supplied snapshot to all overlays, carving out the focused window and related UI.
    func applyOverlayMask(with snapshot: ActiveWindowSnapshot?) {
        guard let snapshot else {
            guard cachedActiveSnapshot == nil, cachedSnapshotsByDisplay.isEmpty else { return }
            overlayWindowsByDisplay.values.forEach { $0.applyMask(regions: []) }
            return
        }

        cacheActiveSnapshot(snapshot)
        applyOverlayMasksFromCache()
    }

    /// Resolves the active window snapshot and updates overlays when it changes.
    /// Starts a repeating timer that samples the focused window position.
    private func startPolling() {
        schedulePollingTimer(with: resolvedPollingInterval)
    }

    /// Stops the polling timer.
    private func stopPolling() {
        snapshotPollingTimer?.invalidate()
        snapshotPollingTimer = nil
        resolvedPollingInterval = activePollingCadence.idleInterval
    }

    /// Reapplies the last known snapshot so new overlay windows pick up current carve-outs.
    private func applyCachedOverlayMask() {
        applyOverlayMasksFromCache()
    }

    /// Updates cached mask metadata for the latest active window snapshot.
    private func cacheActiveSnapshot(_ snapshot: ActiveWindowSnapshot, resolvedDisplayID: DisplayID? = nil) {
        cachedActiveSnapshot = snapshot

        let resolvedID: DisplayID?
        if let providedID = resolvedDisplayID {
            resolvedID = providedID
        } else {
            resolvedID = resolveDisplayIdentifier(for: snapshot.frame)
        }

        if let resolvedID {
            cachedSnapshotsByDisplay[resolvedID] = snapshot
            currentActiveDisplayID = resolvedID
        } else if let activeID = currentActiveDisplayID {
            cachedSnapshotsByDisplay[activeID] = snapshot
        } else {
            currentActiveDisplayID = nil
        }
    }

    /// Applies cached highlight regions to every overlay window.
    private func applyOverlayMasksFromCache() {
        guard !overlayWindowsByDisplay.isEmpty else { return }

        var didApplyMask = false
        var staleDisplayIDs: [DisplayID] = []

        for (displayID, window) in overlayWindowsByDisplay {
            if let cachedSnapshot = cachedSnapshotsByDisplay[displayID] {
                if apply(snapshot: cachedSnapshot, to: window) {
                    didApplyMask = true
                    continue
                } else {
                    staleDisplayIDs.append(displayID)
                }
            }

            if let fallbackSnapshot = cachedActiveSnapshot,
               apply(snapshot: fallbackSnapshot, to: window) {
                cachedSnapshotsByDisplay[displayID] = fallbackSnapshot
                currentActiveDisplayID = displayID
                didApplyMask = true
            } else {
                window.applyMask(regions: [])
            }
        }

        if !staleDisplayIDs.isEmpty {
            for displayID in staleDisplayIDs {
                cachedSnapshotsByDisplay.removeValue(forKey: displayID)
                if currentActiveDisplayID == displayID {
                    currentActiveDisplayID = nil
                }
            }
        }

        if !didApplyMask, cachedSnapshotsByDisplay.isEmpty, cachedActiveSnapshot == nil {
            overlayWindowsByDisplay.values.forEach { $0.applyMask(regions: []) }
        }
    }

    /// Converts an active window snapshot into overlay mask regions for the supplied window.
    private func apply(snapshot: ActiveWindowSnapshot, to window: OverlayWindow) -> Bool {
        guard let contentView = window.contentView else {
            window.applyMask(regions: [])
            return false
        }

        let maskRequests = maskRequests(for: snapshot)
        guard !maskRequests.isEmpty else {
            window.applyMask(regions: [])
            return false
        }

        let windowScreenFrame = window.frame
        var maskRegions: [OverlayWindow.MaskRegion] = []

        for request in maskRequests {
            let expansion = maskExpansion(for: request.purpose)
            let expandedRect = expansion > 0 ? request.rect.insetBy(dx: -expansion, dy: -expansion) : request.rect
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

        guard !maskRegions.isEmpty else {
            window.applyMask(regions: [])
            return false
        }

        window.applyMask(regions: maskRegions)
        return true
    }

    /// Builds mask requests for the supplied snapshot including supplementary carve-outs.
    private func maskRequests(for snapshot: ActiveWindowSnapshot) -> [MaskRequest] {
        var requests: [MaskRequest] = [
            MaskRequest(
                rect: snapshot.frame,
                cornerRadius: snapshot.cornerRadius,
                purpose: .applicationWindow
            )
        ]

        if !snapshot.supplementaryMasks.isEmpty {
            requests.append(contentsOf: snapshot.supplementaryMasks.map {
                MaskRequest(rect: $0.frame, cornerRadius: $0.cornerRadius, purpose: $0.purpose)
            })
        }

        return requests
    }

    /// Attempts to map a window frame to a connected display identifier.
    private func resolveDisplayIdentifier(for frame: NSRect) -> DisplayID? {
        var bestCandidate: (id: DisplayID, area: CGFloat)?

        for (displayID, window) in overlayWindowsByDisplay {
            let intersection = frame.intersection(window.frame)
            let area = max(intersection.width * intersection.height, 0)
            if area > (bestCandidate?.area ?? 0) {
                bestCandidate = (displayID, area)
            }
        }

        if let candidate = bestCandidate, candidate.area > 0 {
            return candidate.id
        }

        var fallbackCandidate: (id: DisplayID, area: CGFloat)?
        for screen in NSScreen.screens {
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            let displayID = DisplayID(truncating: number)
            let intersection = frame.intersection(screen.frame)
            let area = max(intersection.width * intersection.height, 0)
            if area > (fallbackCandidate?.area ?? 0) {
                fallbackCandidate = (displayID, area)
            }
        }

        if let fallback = fallbackCandidate, fallback.area > 0 {
            return fallback.id
        }

        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let matchingScreen = NSScreen.screens.first(where: { $0.frame.contains(center) }),
           let number = matchingScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return DisplayID(truncating: number)
        }

        return nil
    }

    /// Resolves the active window snapshot and updates overlays when it changes.
    @discardableResult
    private func refreshActiveWindowSnapshot() -> Bool {
        let snapshot = activeWindowSnapshotResolver(activeOverlayWindowNumbers())
        let previousSnapshot = cachedActiveSnapshot

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
            overlayWindowsByDisplay.values
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
        if pointerMonitor == nil {
            pointerMonitor = PointerInteractionMonitor { [weak self] state in
                guard let self else { return }
                switch state {
                case .began, .dragged:
                    self.enterInteractionBoost(minimumDuration: self.interactionBoostDuration)
                case .ended:
                    self.enterInteractionBoost(minimumDuration: self.interactionCooldownDuration)
                }
            }
        }
        pointerMonitor?.start()
    }

    /// Tears down the pointer monitor when overlays are inactive.
    private func stopPointerInteractionMonitoring() {
        pointerMonitor?.stop()
        pointerMonitor = nil
        interactionBoostDeadline = nil
        stopDisplayLinkIfNeeded()
    }

    /// Resets and schedules the polling timer with a new interval.
    private func schedulePollingTimer(with interval: TimeInterval) {
        guard interval > 0 else { return }
        snapshotPollingTimer?.invalidate()
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(handlePollingTimer(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        snapshotPollingTimer = timer
        resolvedPollingInterval = interval
    }

    /// Ensures the timer interval matches the requested cadence.
    private func updatePollingIntervalIfNeeded(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        if abs(resolvedPollingInterval - interval) <= 0.0005, snapshotPollingTimer != nil {
            return
        }
        schedulePollingTimer(with: interval)
    }

    /// Resolves the desired interval based on whether a pointer interaction boost is active.
    private func desiredIntervalForCurrentInteractionState() -> TimeInterval {
        if let deadline = interactionBoostDeadline, Date() < deadline {
            if isDisplayLinkActive {
                return max(activePollingCadence.interactionInterval, supplementalSnapshotInterval)
            }
            return activePollingCadence.interactionInterval
        }
        return activePollingCadence.idleInterval
    }

    /// Keeps the high-frequency polling window alive while interactions are active.
    private func enterInteractionBoost(minimumDuration: TimeInterval) {
        guard minimumDuration > 0 else { return }
        let proposedDeadline = Date().addingTimeInterval(minimumDuration)
        if let currentDeadline = interactionBoostDeadline {
            interactionBoostDeadline = max(currentDeadline, proposedDeadline)
        } else {
            interactionBoostDeadline = proposedDeadline
        }
        updatePollingIntervalIfNeeded(activePollingCadence.interactionInterval)
        startDisplayLinkIfNeeded()
    }

    /// Switches back to the idle cadence when interactions have settled for long enough.
    private func evaluateInteractionDeadline() {
        guard let deadline = interactionBoostDeadline else {
            if resolvedPollingInterval != activePollingCadence.idleInterval {
                updatePollingIntervalIfNeeded(activePollingCadence.idleInterval)
            }
            return
        }

        if Date() >= deadline {
            interactionBoostDeadline = nil
            updatePollingIntervalIfNeeded(activePollingCadence.idleInterval)
            stopDisplayLinkIfNeeded()
        } else {
            updatePollingIntervalIfNeeded(activePollingCadence.interactionInterval)
        }
    }

    private func startDisplayLinkIfNeeded() {
        guard !isDisplayLinkActive else { return }
        if supplementalDisplayLink.start() {
            isDisplayLinkActive = true
        }
    }

    private func stopDisplayLinkIfNeeded() {
        guard isDisplayLinkActive else { return }
        supplementalDisplayLink.stop()
        isDisplayLinkActive = false
    }

    private func handleDisplayLinkTick() {
        guard isMonitoring else { return }
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

        if var cachedSnapshot = cachedActiveSnapshot {
            let tolerance: CGFloat = 0.35
            if cachedSnapshot.frame.isApproximatelyEqual(to: cgFrame, tolerance: tolerance) {
                return .noChange
            }

            cachedSnapshot = ActiveWindowSnapshot(
                frame: cgFrame,
                cornerRadius: cachedSnapshot.cornerRadius,
                supplementaryMasks: cachedSnapshot.supplementaryMasks
            )
            cacheActiveSnapshot(cachedSnapshot)
            applyOverlayMasksFromCache()
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
