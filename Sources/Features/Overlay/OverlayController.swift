// Permissions (TCC):
// - Accessibility: required to retrieve focused window frames.
// - App Store: feature category "system-wide overlays" is often review-sensitive.

import AppKit

/// Keeps OverlayWindow instances synchronized with the focused window and display configuration.
@MainActor
final class OverlayController {
    /// Groups the idle and interaction intervals used when polling the focused window.
    private struct PollingCadence {
        let idleInterval: TimeInterval
        let interactionInterval: TimeInterval

        init(profile: WindowTrackingProfile) {
            self.idleInterval = profile.idleInterval
            self.interactionInterval = profile.interactionInterval
        }
    }

    /// Describes a single carve-out request that will be applied to an overlay mask.
    private struct MaskRequest {
        let rect: NSRect
        let cornerRadius: CGFloat
        let purpose: ActiveWindowSnapshot.MaskRegion.Purpose?
    }

    private let interactionBoostDuration: TimeInterval = 0.6
    private let interactionCooldownDuration: TimeInterval = 0.25
    private let supplementalSnapshotInterval: TimeInterval = 1.0 / 15.0
    private let activeWindowSnapshotResolver: (Set<Int>) -> ActiveWindowSnapshot?

    private var overlayWindowsByDisplayID: [DisplayID: OverlayWindow] = [:]
    private var snapshotPollingTimer: Timer?
    private var currentTrackingProfile: WindowTrackingProfile
    private var currentPollingCadence: PollingCadence
    private var currentPollingInterval: TimeInterval
    private var interactionBoostExpiration: Date?
    private var isClickThroughEnabled = true
    private var isMonitoringActive = false
    private var cachedActiveSnapshot: ActiveWindowSnapshot?
    private var cachedSnapshotsByDisplayID: [DisplayID: ActiveWindowSnapshot] = [:]
    private var activeDisplayID: DisplayID?
    private var pointerInteractionMonitor: PointerInteractionMonitor?
    private lazy var supplementalSnapshotDisplayLink = DisplayLinkDriver { [weak self] in
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
        self.currentTrackingProfile = .standard
        self.currentPollingCadence = PollingCadence(profile: .standard)
        self.currentPollingInterval = currentPollingCadence.idleInterval
    }

    /// Begins monitoring the focused window and updates overlay masks accordingly.
    func start() {
        guard !isMonitoringActive else { return }
        isMonitoringActive = true
        configurePointerInteractionMonitoring()
        startPolling()
        applyCachedOverlayMask()
        if cachedActiveSnapshot == nil {
            refreshActiveWindowSnapshot()
        }
    }

    /// Stops monitoring and clears active overlay carve-outs.
    func stop() {
        guard isMonitoringActive else { return }
        isMonitoringActive = false
        stopPolling()
        stopPointerInteractionMonitoring()
        stopDisplayLinkIfNeeded()
        cachedActiveSnapshot = nil
        cachedSnapshotsByDisplayID.removeAll()
        activeDisplayID = nil
        overlayWindowsByDisplayID.values.forEach { $0.applyMask(regions: []) }
    }

    /// Toggles whether overlay windows forward mouse events to windows underneath.
    func setClickThrough(_ enabled: Bool) {
        isClickThroughEnabled = enabled
        overlayWindowsByDisplayID.values.forEach { $0.setClickThrough(enabled) }
    }

    /// Updates the polling cadence to match the selected tracking profile.
    func updateTrackingProfile(_ profile: WindowTrackingProfile) {
        guard currentTrackingProfile != profile else { return }
        currentTrackingProfile = profile
        currentPollingCadence = PollingCadence(profile: profile)
        let targetInterval = desiredIntervalForCurrentInteractionState()
        currentPollingInterval = targetInterval
        if isMonitoringActive {
            schedulePollingTimer(with: targetInterval)
        }
    }

    /// Seeds the controller with an initial snapshot so overlays can immediately carve it out.
    func primeOverlayMask(with snapshot: ActiveWindowSnapshot?) {
        if let snapshot {
            cacheActiveSnapshot(snapshot)
        } else {
            cachedActiveSnapshot = nil
            cachedSnapshotsByDisplayID.removeAll()
            activeDisplayID = nil
        }
        if isMonitoringActive {
            applyCachedOverlayMask()
        }
    }

    /// Replaces the overlay window map, cleaning up removed displays and applying cached masks.
    func refreshOverlayWindows(_ updatedOverlayWindows: [DisplayID: OverlayWindow]) {
        let previousOverlayWindows = overlayWindowsByDisplayID
        overlayWindowsByDisplayID = updatedOverlayWindows

        let removedDisplayIDs = Set(previousOverlayWindows.keys).subtracting(updatedOverlayWindows.keys)
        for displayID in removedDisplayIDs {
            previousOverlayWindows[displayID]?.applyMask(regions: [])
        }

        let updatedDisplayIDs = Set(updatedOverlayWindows.keys)
        cachedSnapshotsByDisplayID = cachedSnapshotsByDisplayID.filter { updatedDisplayIDs.contains($0.key) }
        if let activeID = activeDisplayID, !updatedDisplayIDs.contains(activeID) {
            activeDisplayID = nil
        }

        overlayWindowsByDisplayID.values.forEach { $0.setClickThrough(isClickThroughEnabled) }

        if isMonitoringActive {
            applyCachedOverlayMask()
        }
    }

    /// Applies the supplied snapshot to all overlays, carving out the focused window and related UI.
    func applyOverlayMask(with snapshot: ActiveWindowSnapshot?) {
        guard let snapshot else {
            guard cachedActiveSnapshot == nil, cachedSnapshotsByDisplayID.isEmpty else { return }
            overlayWindowsByDisplayID.values.forEach { $0.applyMask(regions: []) }
            return
        }

        cacheActiveSnapshot(snapshot)
        applyOverlayMasksFromCache()
    }

    /// Resolves the active window snapshot and updates overlays when it changes.
    /// Starts a repeating timer that samples the focused window position.
    private func startPolling() {
        schedulePollingTimer(with: currentPollingInterval)
    }

    /// Stops the polling timer.
    private func stopPolling() {
        snapshotPollingTimer?.invalidate()
        snapshotPollingTimer = nil
        currentPollingInterval = currentPollingCadence.idleInterval
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
            cachedSnapshotsByDisplayID[resolvedID] = snapshot
            activeDisplayID = resolvedID
        } else if let activeID = activeDisplayID {
            cachedSnapshotsByDisplayID[activeID] = snapshot
        } else {
            activeDisplayID = nil
        }
    }

    /// Applies cached highlight regions to every overlay window.
    private func applyOverlayMasksFromCache() {
        guard !overlayWindowsByDisplayID.isEmpty else { return }

        var didApplyMask = false
        var staleDisplayIDs: [DisplayID] = []

        for (displayID, window) in overlayWindowsByDisplayID {
            if let cachedSnapshot = cachedSnapshotsByDisplayID[displayID] {
                if apply(snapshot: cachedSnapshot, to: window) {
                    didApplyMask = true
                    continue
                } else {
                    staleDisplayIDs.append(displayID)
                }
            }

            if let fallbackSnapshot = cachedActiveSnapshot,
               apply(snapshot: fallbackSnapshot, to: window) {
                cachedSnapshotsByDisplayID[displayID] = fallbackSnapshot
                activeDisplayID = displayID
                didApplyMask = true
            } else {
                window.applyMask(regions: [])
            }
        }

        if !staleDisplayIDs.isEmpty {
            for displayID in staleDisplayIDs {
                cachedSnapshotsByDisplayID.removeValue(forKey: displayID)
                if activeDisplayID == displayID {
                    activeDisplayID = nil
                }
            }
        }

        if !didApplyMask, cachedSnapshotsByDisplayID.isEmpty, cachedActiveSnapshot == nil {
            overlayWindowsByDisplayID.values.forEach { $0.applyMask(regions: []) }
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

        let backingScale = window.backingScaleFactor

        for request in maskRequests {
            let expansion = maskExpansion(for: request.purpose)
            let expandedRect = expansion != 0 ? request.rect.insetBy(dx: -expansion, dy: -expansion) : request.rect
            let screenIntersection = expandedRect.intersection(windowScreenFrame)
            guard !screenIntersection.isNull else { continue }

            let windowRect = window.convertFromScreen(screenIntersection)
            let rectInContent = contentView.convert(windowRect, from: nil)
            let normalizedRect = rectInContent.intersection(contentView.bounds)
            guard !normalizedRect.isNull else { continue }

            let shrink = maskShrink(for: request.purpose, rect: normalizedRect)
            let clampedShrink = min(shrink, max(0, min(normalizedRect.width, normalizedRect.height) / 2))
            let insetRect = clampedShrink > 0 ? normalizedRect.insetBy(dx: clampedShrink, dy: clampedShrink) : normalizedRect
            guard insetRect.width > 0, insetRect.height > 0 else { continue }

            let backingAligned = contentView.convertToBacking(insetRect).integral
            let finalRect = contentView.convertFromBacking(backingAligned)
            guard finalRect.width > 0, finalRect.height > 0 else { continue }

            maskRegions.append(
                OverlayWindow.MaskRegion(
                    rect: finalRect,
                    cornerRadius: adjustedCornerRadius(for: request, expansion: expansion, shrink: clampedShrink, scale: backingScale)
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

        for (displayID, window) in overlayWindowsByDisplayID {
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
            overlayWindowsByDisplayID.values
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
        case .systemMenu?:
            return 0.07
        case .applicationMenu?:
            return 0.06
        case .applicationWindow?:
            return 0.1
        case nil:
            return 0.1
        }
    }

    /// Slightly shrinks carved-out menus so their edges remain pixel-tight after rounding.
    private func maskShrink(for purpose: ActiveWindowSnapshot.MaskRegion.Purpose?, rect: NSRect) -> CGFloat {
        switch purpose {
        case .systemMenu?, .applicationMenu?:
            return min(0.35, min(rect.width, rect.height) * 0.3)
        case .applicationWindow?, nil:
            return 0
        }
    }

    /// Adjusts the corner radius to match the expanded mask rect.
    private func adjustedCornerRadius(for request: MaskRequest, expansion: CGFloat, shrink: CGFloat, scale: CGFloat) -> CGFloat {
        let baseRadius = max(0, request.cornerRadius)
        let expanded = expansion > 0 ? baseRadius + expansion : baseRadius
        guard shrink > 0 else {
            return max(0, expanded + cornerRadiusBias(for: request.purpose))
        }

        let pixelEpsilon = scale > 0 ? (0.5 / scale) : 0
        let adjusted = max(0, expanded - max(0, shrink - pixelEpsilon))
        return max(0, adjusted + cornerRadiusBias(for: request.purpose))
    }

    /// Introduces a subtle bias so menu carve-outs keep their rounded edges distinctive.
    private func cornerRadiusBias(for purpose: ActiveWindowSnapshot.MaskRegion.Purpose?) -> CGFloat {
        switch purpose {
        case .systemMenu?:
            return -0.12
        case .applicationMenu?:
            return -0.08
        default:
            return 0
        }
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
        interactionBoostExpiration = nil
        stopDisplayLinkIfNeeded()
    }

    /// Resets and schedules the polling timer with a new interval.
    private func schedulePollingTimer(with interval: TimeInterval) {
        guard interval > 0 else { return }
        snapshotPollingTimer?.invalidate()
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(handlePollingTimer(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        snapshotPollingTimer = timer
        currentPollingInterval = interval
    }

    /// Ensures the timer interval matches the requested cadence.
    private func updatePollingIntervalIfNeeded(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        if abs(currentPollingInterval - interval) <= 0.0005, snapshotPollingTimer != nil {
            return
        }
        schedulePollingTimer(with: interval)
    }

    /// Resolves the desired interval based on whether a pointer interaction boost is active.
    private func desiredIntervalForCurrentInteractionState() -> TimeInterval {
        if let deadline = interactionBoostExpiration, Date() < deadline {
            if isDisplayLinkRunning {
                return max(currentPollingCadence.interactionInterval, supplementalSnapshotInterval)
            }
            return currentPollingCadence.interactionInterval
        }
        return currentPollingCadence.idleInterval
    }

    /// Keeps the high-frequency polling window alive while interactions are active.
    private func enterInteractionBoost(minimumDuration: TimeInterval) {
        guard minimumDuration > 0 else { return }
        let proposedDeadline = Date().addingTimeInterval(minimumDuration)
        if let currentDeadline = interactionBoostExpiration {
            interactionBoostExpiration = max(currentDeadline, proposedDeadline)
        } else {
            interactionBoostExpiration = proposedDeadline
        }
        updatePollingIntervalIfNeeded(currentPollingCadence.interactionInterval)
        startDisplayLinkIfNeeded()
    }

    /// Switches back to the idle cadence when interactions have settled for long enough.
    private func evaluateInteractionDeadline() {
        guard let deadline = interactionBoostExpiration else {
            if currentPollingInterval != currentPollingCadence.idleInterval {
                updatePollingIntervalIfNeeded(currentPollingCadence.idleInterval)
            }
            return
        }

        if Date() >= deadline {
            interactionBoostExpiration = nil
            updatePollingIntervalIfNeeded(currentPollingCadence.idleInterval)
            stopDisplayLinkIfNeeded()
        } else {
            updatePollingIntervalIfNeeded(currentPollingCadence.interactionInterval)
        }
    }

    /// Starts the supplemental display link used during drag interactions.
    private func startDisplayLinkIfNeeded() {
        guard !isDisplayLinkRunning else { return }
        if supplementalSnapshotDisplayLink.start() {
            isDisplayLinkRunning = true
        }
    }

    /// Stops the supplemental display link when higher-frequency updates are no longer needed.
    private func stopDisplayLinkIfNeeded() {
        guard isDisplayLinkRunning else { return }
        supplementalSnapshotDisplayLink.stop()
        isDisplayLinkRunning = false
    }

    /// Runs on the supplemental display link to keep mask geometry in sync during active interactions.
    private func handleDisplayLinkTick() {
        guard isMonitoringActive else { return }
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
