// Permissions (TCC):
// - Accessibility: required to retrieve focused window frames.
// - App Store: feature category "system-wide overlays" is often review-sensitive.

import AppKit
import os.log

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
    private struct MaskRequest: Equatable {
        let rect: NSRect
        let cornerRadius: CGFloat
        let purpose: ActiveWindowSnapshot.MaskRegion.Purpose?

        static func == (lhs: MaskRequest, rhs: MaskRequest) -> Bool {
            lhs.rect.isApproximatelyEqual(to: rhs.rect, tolerance: 0.05) &&
            abs(lhs.cornerRadius - rhs.cornerRadius) <= 0.05 &&
            lhs.purpose == rhs.purpose
        }
    }

    private let interactionBoostDuration: TimeInterval = 0.6
    private let interactionCooldownDuration: TimeInterval = 0.25
    private let activeWindowSnapshotResolver: (Set<Int>, Bool) -> ActiveWindowSnapshot?
    private let minimumPredictionDelta: CGFloat = 0.32

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
    private var predictedSnapshotsByDisplayID: [DisplayID: ActiveWindowSnapshot] = [:]
    private var activeDisplayID: DisplayID?
    private var pointerInteractionMonitor: PointerInteractionMonitor?
    private var pointerHoverMonitor: PointerHoverMonitor?
    private var lastPointerLocation: NSPoint?
    private var peripheralMaskRequestsByDisplayID: [DisplayID: [MaskRequest]] = [:]
    private var cachedPeripheralRegions: [PeripheralInterfaceRegion] = []
    private var lastPeripheralRegionRefresh = Date.distantPast
    private let peripheralRegionCacheLifetime: TimeInterval = 0.25
    private var isDesktopPeripheralRevealEnabled = true
    private lazy var supplementalSnapshotDisplayLink = DisplayLinkDriver { [weak self] timing in
        guard let self else { return }
        self.handleDisplayLinkTick(timing: timing)
    }
    private var isDisplayLinkRunning = false
    private var lastDisplayLinkRefreshInterval: TimeInterval = 1.0 / 60.0
    private let motionPredictor = WindowMotionPredictor()
    private let fastFrameSampleInterval: TimeInterval = 1.0 / 75.0
    private var lastFastFrameHostTime: UInt64 = 0
    private static let hostTimeToSecondsFactor: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        let nanosecondsPerTick = Double(info.numer) / Double(info.denom)
        return nanosecondsPerTick / 1_000_000_000.0
    }()
    private var nextMaskDiagnosticsLogDate = Date.distantPast
    private let maskDiagnosticsLogger = Logger(subsystem: "com.focusly.app", category: "OverlayMask")
    private var defaultApplicationMaskingMode: ApplicationMaskingMode = .allApplicationWindows
    private var maskingModeOverrides: [DisplayID: ApplicationMaskingMode] = [:]
    private var isApplicationWideSnapshotEnabled = true

    init(
        activeWindowSnapshotResolver: @escaping (Set<Int>, Bool) -> ActiveWindowSnapshot? = { windowNumbers, includeApplicationWindows in
            resolveActiveWindowSnapshot(excluding: windowNumbers, includeAllApplicationWindows: includeApplicationWindows)
        }
    ) {
        self.activeWindowSnapshotResolver = activeWindowSnapshotResolver
        self.currentTrackingProfile = .standard
        self.currentPollingCadence = PollingCadence(profile: .standard)
        self.currentPollingInterval = currentPollingCadence.idleInterval
    }

    /// Indicates whether any display currently prefers application-wide carving.
    var prefersApplicationWideMasking: Bool {
        shouldIncludeApplicationWindows()
    }

    /// Begins monitoring the focused window and updates overlay masks accordingly.
    func start() {
        guard !isMonitoringActive else { return }
        isMonitoringActive = true
        configurePointerInteractionMonitoring()
        startPointerHoverMonitoring()
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
        stopPointerHoverMonitoring()
        stopDisplayLinkIfNeeded()
        cachedActiveSnapshot = nil
        cachedSnapshotsByDisplayID.removeAll()
        predictedSnapshotsByDisplayID.removeAll()
        activeDisplayID = nil
        motionPredictor.reset()
        updateDisplayLinkPreferredDisplay()
        lastDisplayLinkRefreshInterval = 1.0 / 60.0
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
            predictedSnapshotsByDisplayID.removeAll()
            activeDisplayID = nil
            motionPredictor.reset()
            updateDisplayLinkPreferredDisplay()
        }
        if isMonitoringActive {
            applyCachedOverlayMask()
        }
    }

    /// Returns the display identifier currently associated with the focused window snapshot, if any.
    func activeDisplayIdentifier() -> DisplayID? {
        activeDisplayID
    }

    /// Updates the fallback masking mode applied to displays without explicit overrides.
    func setDefaultApplicationMaskingMode(_ mode: ApplicationMaskingMode) {
        guard defaultApplicationMaskingMode != mode else { return }
        defaultApplicationMaskingMode = mode
        updateApplicationWideSnapshotFlag()
        applyCachedOverlayMask()
    }

    /// Overrides the masking mode for a specific display identifier.
    func setApplicationMaskingMode(_ mode: ApplicationMaskingMode, for displayID: DisplayID) {
        if mode == defaultApplicationMaskingMode {
            if maskingModeOverrides.removeValue(forKey: displayID) != nil {
                updateApplicationWideSnapshotFlag()
                applyCachedOverlayMask()
            } else {
                updateApplicationWideSnapshotFlag()
            }
            return
        }
        if maskingModeOverrides[displayID] == mode {
            return
        }
        maskingModeOverrides[displayID] = mode
        updateApplicationWideSnapshotFlag()
        applyCachedOverlayMask()
    }

    /// Enables or disables automatic Dock/Stage Manager reveal when only the desktop is focused.
    func setDesktopPeripheralRevealEnabled(_ enabled: Bool) {
        guard isDesktopPeripheralRevealEnabled != enabled else { return }
        isDesktopPeripheralRevealEnabled = enabled
        rebuildPeripheralHoverState()
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
        predictedSnapshotsByDisplayID = predictedSnapshotsByDisplayID.filter { updatedDisplayIDs.contains($0.key) }
        var didMutateActiveDisplay = false
        if let activeID = activeDisplayID, !updatedDisplayIDs.contains(activeID) {
            activeDisplayID = nil
            didMutateActiveDisplay = true
        }

        overlayWindowsByDisplayID.values.forEach { $0.setClickThrough(isClickThroughEnabled) }

        if isMonitoringActive {
            applyCachedOverlayMask()
        }
        if didMutateActiveDisplay {
            updateDisplayLinkPreferredDisplay()
        }
        updateApplicationWideSnapshotFlag()
        refreshPeripheralRegionsIfNeeded(force: true)
        updatePeripheralHoverState(for: NSEvent.mouseLocation)
    }

    /// Applies the supplied snapshot to all overlays, carving out the focused window and related UI.
    func applyOverlayMask(with snapshot: ActiveWindowSnapshot?) {
        guard let snapshot else {
            cachedActiveSnapshot = nil
            cachedSnapshotsByDisplayID.removeAll()
            predictedSnapshotsByDisplayID.removeAll()
            activeDisplayID = nil
            motionPredictor.reset()
            updateDisplayLinkPreferredDisplay()
            rebuildPeripheralHoverState()
            applyOverlayMasksFromCache()
            return
        }

        cacheActiveSnapshot(snapshot)
        applyOverlayMasksFromCache()
    }

    private func maskingMode(for displayID: DisplayID) -> ApplicationMaskingMode {
        maskingModeOverrides[displayID] ?? defaultApplicationMaskingMode
    }

    private func shouldIncludeApplicationWindows() -> Bool {
        if overlayWindowsByDisplayID.isEmpty {
            if defaultApplicationMaskingMode == .allApplicationWindows {
                return true
            }
            return maskingModeOverrides.values.contains { $0 == .allApplicationWindows }
        }

        for displayID in overlayWindowsByDisplayID.keys {
            if maskingMode(for: displayID) == .allApplicationWindows {
                return true
            }
        }
        return false
    }

    private func updateApplicationWideSnapshotFlag() {
        let desiredState = shouldIncludeApplicationWindows()
        guard desiredState != isApplicationWideSnapshotEnabled else { return }
        isApplicationWideSnapshotEnabled = desiredState
        _ = refreshActiveWindowSnapshot()
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

    /// Keeps the display-link driver in sync with the display being actively carved out.
    private func updateDisplayLinkPreferredDisplay() {
        supplementalSnapshotDisplayLink.setPreferredDisplayID(activeDisplayID)
    }

    /// Periodically logs how often we fall back to bitmap mask rendering.
    private func evaluateMaskRenderingDiagnosticsIfNeeded() {
        let now = Date()
        guard now >= nextMaskDiagnosticsLogDate else { return }
        let diagnostics = OverlayWindow.maskRenderingDiagnostics()
        guard diagnostics.totalFrames >= 90 else { return }
        let fallbackRatio = diagnostics.bitmapRatio
        if fallbackRatio > 0.35 {
            let fallbackPercent = fallbackRatio * 100
            maskDiagnosticsLogger.notice(
                "Overlay mask bitmap fallback ratio \(fallbackPercent, format: .fixed(precision: 2), privacy: .public)% (vector: \(diagnostics.vectorFrames, privacy: .public), bitmap: \(diagnostics.bitmapFrames, privacy: .public))"
            )
        }
        nextMaskDiagnosticsLogDate = now.addingTimeInterval(8)
    }

    /// Updates cached mask metadata for the latest active window snapshot.
    private func cacheActiveSnapshot(_ snapshot: ActiveWindowSnapshot, resolvedDisplayID: DisplayID? = nil) {
        cachedActiveSnapshot = snapshot
        motionPredictor.record(frame: snapshot.frame)

        let resolvedID: DisplayID?
        if let providedID = resolvedDisplayID {
            resolvedID = providedID
        } else {
            resolvedID = resolveDisplayIdentifier(for: snapshot.frame)
        }

        if let resolvedID {
            cachedSnapshotsByDisplayID[resolvedID] = snapshot
            predictedSnapshotsByDisplayID.removeValue(forKey: resolvedID)
            activeDisplayID = resolvedID
        } else if let activeID = activeDisplayID {
            cachedSnapshotsByDisplayID[activeID] = snapshot
            predictedSnapshotsByDisplayID.removeValue(forKey: activeID)
        } else {
            activeDisplayID = nil
            predictedSnapshotsByDisplayID.removeAll()
        }

        updateDisplayLinkPreferredDisplay()
        rebuildPeripheralHoverState()
    }

    /// Applies cached highlight regions to every overlay window.
    private func applyOverlayMasksFromCache() {
        guard !overlayWindowsByDisplayID.isEmpty else { return }

        var didApplyMask = false
        var staleDisplayIDs: [DisplayID] = []
        var didMutateActiveDisplay = false

        for (displayID, window) in overlayWindowsByDisplayID {
            var applied = false

            if let predictedSnapshot = predictedSnapshotsByDisplayID[displayID] {
                if apply(snapshot: predictedSnapshot, to: window, displayID: displayID) {
                    didApplyMask = true
                    applied = true
                } else {
                    predictedSnapshotsByDisplayID.removeValue(forKey: displayID)
                }
            }

            if !applied, let cachedSnapshot = cachedSnapshotsByDisplayID[displayID] {
                if apply(snapshot: cachedSnapshot, to: window, displayID: displayID) {
                    didApplyMask = true
                    applied = true
                    predictedSnapshotsByDisplayID.removeValue(forKey: displayID)
                } else {
                    staleDisplayIDs.append(displayID)
                }
            }

            if !applied, let fallbackSnapshot = cachedActiveSnapshot,
               apply(snapshot: fallbackSnapshot, to: window, displayID: displayID) {
                cachedSnapshotsByDisplayID[displayID] = fallbackSnapshot
                predictedSnapshotsByDisplayID.removeValue(forKey: displayID)
                activeDisplayID = displayID
                didMutateActiveDisplay = true
                didApplyMask = true
                applied = true
            }

            if !applied {
                if applyPeripheralMasksIfNeeded(to: window, displayID: displayID) {
                    didApplyMask = true
                } else {
                    window.applyMask(regions: [])
                }
            }
        }

        if !staleDisplayIDs.isEmpty {
            for displayID in staleDisplayIDs {
                cachedSnapshotsByDisplayID.removeValue(forKey: displayID)
                if activeDisplayID == displayID {
                    activeDisplayID = nil
                    didMutateActiveDisplay = true
                }
            }
        }

        if didMutateActiveDisplay {
            updateDisplayLinkPreferredDisplay()
        }

        evaluateMaskRenderingDiagnosticsIfNeeded()

        if !didApplyMask,
           cachedSnapshotsByDisplayID.isEmpty,
           cachedActiveSnapshot == nil,
           peripheralMaskRequestsByDisplayID.isEmpty {
            overlayWindowsByDisplayID.values.forEach { $0.applyMask(regions: []) }
        }
    }

    /// Converts an active window snapshot into overlay mask regions for the supplied window.
    private func apply(snapshot: ActiveWindowSnapshot, to window: OverlayWindow, displayID: DisplayID) -> Bool {
        var requests = maskRequests(for: snapshot, mode: maskingMode(for: displayID))
        if let peripheralRequests = peripheralMaskRequestsByDisplayID[displayID], !peripheralRequests.isEmpty {
            requests.append(contentsOf: peripheralRequests)
        }
        return apply(maskRequests: requests, to: window)
    }

    /// Builds mask requests for the supplied snapshot including supplementary carve-outs.
    private func maskRequests(for snapshot: ActiveWindowSnapshot, mode: ApplicationMaskingMode) -> [MaskRequest] {
        var requests: [MaskRequest] = [
            MaskRequest(
                rect: snapshot.frame,
                cornerRadius: snapshot.cornerRadius,
                purpose: .applicationWindow
            )
        ]

        if !snapshot.supplementaryMasks.isEmpty {
            for region in snapshot.supplementaryMasks {
                if region.purpose == .applicationWindow, mode == .focusedWindow {
                    continue
                }
                requests.append(
                    MaskRequest(rect: region.frame, cornerRadius: region.cornerRadius, purpose: region.purpose)
                )
            }
        }

        return requests
    }

    /// Applies the supplied mask requests to the overlay window, accounting for blur tolerances.
    private func apply(maskRequests: [MaskRequest], to window: OverlayWindow) -> Bool {
        guard let contentView = window.contentView else {
            window.applyMask(regions: [])
            return false
        }
        guard !maskRequests.isEmpty else {
            window.applyMask(regions: [])
            return false
        }

        let windowScreenFrame = window.frame
        var maskRegions: [OverlayWindow.MaskRegion] = []
        maskRegions.reserveCapacity(maskRequests.count)

        let backingScale = window.backingScaleFactor

        for request in maskRequests {
            let expansion = maskExpansion(for: request.purpose)
            let baseIntersection = request.rect.intersection(windowScreenFrame)
            guard !baseIntersection.isNull else { continue }

            let expandedRect: NSRect
            if expansion != 0 {
                let expanded = baseIntersection.insetBy(dx: -expansion, dy: -expansion)
                expandedRect = expanded.intersection(windowScreenFrame)
            } else {
                expandedRect = baseIntersection
            }
            guard !expandedRect.isNull else { continue }

            let windowRect = window.convertFromScreen(expandedRect)
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

    /// Applies only peripheral carve-outs when no active window snapshot is available.
    private func applyPeripheralMasksIfNeeded(to window: OverlayWindow, displayID: DisplayID) -> Bool {
        guard let requests = peripheralMaskRequestsByDisplayID[displayID], !requests.isEmpty else {
            window.applyMask(regions: [])
            return false
        }
        return apply(maskRequests: requests, to: window)
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
        let snapshot = activeWindowSnapshotResolver(activeOverlayWindowNumbers(), isApplicationWideSnapshotEnabled)
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

    /// Begins tracking global pointer movement so Dock/Stage Manager can be carved out on hover.
    private func startPointerHoverMonitoring() {
        if pointerHoverMonitor == nil {
            pointerHoverMonitor = PointerHoverMonitor { [weak self] location in
                guard let self else { return }
                self.updatePeripheralHoverState(for: location)
            }
        }
        pointerHoverMonitor?.start()
        let initialLocation = NSEvent.mouseLocation
        lastPointerLocation = initialLocation
        refreshPeripheralRegionsIfNeeded(force: true)
        updatePeripheralHoverState(for: initialLocation)
    }

    /// Stops hover tracking and clears any stale peripheral carve-outs.
    private func stopPointerHoverMonitoring() {
        pointerHoverMonitor?.stop()
        pointerHoverMonitor = nil
        lastPointerLocation = nil
        cachedPeripheralRegions = []
        lastPeripheralRegionRefresh = .distantPast
        if !peripheralMaskRequestsByDisplayID.isEmpty {
            peripheralMaskRequestsByDisplayID.removeAll()
            if isMonitoringActive {
                applyCachedOverlayMask()
            }
        }
    }

    /// Keeps peripheral region caches fresh without hammering CoreGraphics every mouse move.
    private func refreshPeripheralRegionsIfNeeded(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastPeripheralRegionRefresh) < peripheralRegionCacheLifetime {
            return
        }
        let exclusionNumbers = activeOverlayWindowNumbers()
        cachedPeripheralRegions = resolvePeripheralInterfaceRegions(excluding: exclusionNumbers)
        lastPeripheralRegionRefresh = now
    }

    /// Recomputes hover-dependent carve-outs for Dock/Stage Manager surfaces.
    private func updatePeripheralHoverState(for location: NSPoint) {
        guard isMonitoringActive else { return }
        lastPointerLocation = location
        refreshPeripheralRegionsIfNeeded()
        let revealAll = shouldForcePeripheralReveal()
        let updatedRequests = buildPeripheralMaskRequests(for: location, forceRevealAll: revealAll)
        if peripheralRequestsAreEqual(updatedRequests, peripheralMaskRequestsByDisplayID) {
            return
        }
        peripheralMaskRequestsByDisplayID = updatedRequests
        applyCachedOverlayMask()
    }

    /// Reapplies the current hover state using the last known pointer position.
    private func rebuildPeripheralHoverState() {
        let location = lastPointerLocation ?? NSEvent.mouseLocation
        updatePeripheralHoverState(for: location)
    }

    /// Builds mask requests for any peripheral region currently under the pointer.
    private func buildPeripheralMaskRequests(for location: NSPoint, forceRevealAll: Bool) -> [DisplayID: [MaskRequest]] {
        guard !cachedPeripheralRegions.isEmpty else { return [:] }
        var requests: [DisplayID: [MaskRequest]] = [:]
        for region in cachedPeripheralRegions {
            if !forceRevealAll && !region.hoverRect.contains(location) {
                continue
            }
            guard overlayWindowsByDisplayID[region.displayID] != nil else { continue }
            let request = MaskRequest(rect: region.frame, cornerRadius: region.cornerRadius, purpose: .systemMenu)
            requests[region.displayID, default: []].append(request)
        }
        return requests
    }

    /// Determines whether Dock/Stage Manager should be revealed regardless of pointer position.
    private func shouldForcePeripheralReveal() -> Bool {
        guard isDesktopPeripheralRevealEnabled else { return false }
        return cachedActiveSnapshot == nil
    }

    /// Returns whether two dictionaries of mask requests describe the same carve-outs.
    private func peripheralRequestsAreEqual(
        _ lhs: [DisplayID: [MaskRequest]],
        _ rhs: [DisplayID: [MaskRequest]]
    ) -> Bool {
        if lhs.count != rhs.count { return false }
        for (displayID, leftRequests) in lhs {
            guard var rightRequests = rhs[displayID] else { return false }
            if leftRequests.count != rightRequests.count { return false }
            rightRequests = sortedMaskRequests(rightRequests)
            let sortedLeft = sortedMaskRequests(leftRequests)
            for (left, right) in zip(sortedLeft, rightRequests) where left != right {
                return false
            }
        }
        return true
    }

    /// Produces a stable ordering for mask request comparisons.
    private func sortedMaskRequests(_ requests: [MaskRequest]) -> [MaskRequest] {
        requests.sorted { lhs, rhs in
            if lhs.rect.origin.y != rhs.rect.origin.y {
                return lhs.rect.origin.y < rhs.rect.origin.y
            }
            if lhs.rect.origin.x != rhs.rect.origin.x {
                return lhs.rect.origin.x < rhs.rect.origin.x
            }
            if lhs.rect.size.width != rhs.rect.size.width {
                return lhs.rect.size.width < rhs.rect.size.width
            }
            if lhs.rect.size.height != rhs.rect.size.height {
                return lhs.rect.size.height < rhs.rect.size.height
            }
            if lhs.cornerRadius != rhs.cornerRadius {
                return lhs.cornerRadius < rhs.cornerRadius
            }
            let lhsPurpose = lhs.purpose ?? .applicationWindow
            let rhsPurpose = rhs.purpose ?? .applicationWindow
            return maskPurposeRank(lhsPurpose) < maskPurposeRank(rhsPurpose)
        }
    }

    /// Provides a deterministic ordering so peripheral requests stay stable.
    private func maskPurposeRank(_ purpose: ActiveWindowSnapshot.MaskRegion.Purpose) -> Int {
        switch purpose {
        case .applicationWindow:
            return 0
        case .applicationMenu:
            return 1
        case .systemMenu:
            return 2
        }
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
                return max(currentPollingCadence.interactionInterval, lastDisplayLinkRefreshInterval)
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
        supplementalSnapshotDisplayLink.setPreferredDisplayID(activeDisplayID)
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
    private func handleDisplayLinkTick(timing: DisplayLinkFrameTiming) {
        guard isMonitoringActive else { return }
        let normalizedInterval = normalizedRefreshInterval(timing.refreshPeriod)
        lastDisplayLinkRefreshInterval = normalizedInterval
        applyPredictedFrameIfPossible(leadTime: normalizedInterval)
        if shouldPerformFastFrameSample(hostTime: timing.hostTime) {
            lastFastFrameHostTime = timing.hostTime
            switch refreshActiveWindowFrameFast() {
            case .updated, .noChange:
                break
            case .needsFallback:
                _ = refreshActiveWindowSnapshot()
            }
        }
        evaluateInteractionDeadline()
    }

    private enum FrameRefreshResult {
        case updated
        case noChange
        case needsFallback
    }

    /// Keeps refresh intervals sane when displays report oddball values.
    private func normalizedRefreshInterval(_ period: TimeInterval) -> TimeInterval {
        guard period.isFinite, period > 0 else { return lastDisplayLinkRefreshInterval }
        let minimum = 1.0 / 240.0
        let maximum = 1.0 / 24.0
        return min(max(period, minimum), maximum)
    }

    /// Boosts the lead time for higher-refresh displays so overlays stay ahead of rapid panels.
    private func predictiveLeadMultiplier(for interval: TimeInterval) -> Double {
        guard interval > 0 else { return 1 }
        if interval < (1.0 / 120.0) {
            return 1.65
        }
        if interval < (1.0 / 90.0) {
            return 1.35
        }
        return 1.0
    }

    /// Returns whether we should refresh the live CoreGraphics snapshot on this display-link tick.
    private func shouldPerformFastFrameSample(hostTime: UInt64) -> Bool {
        if cachedActiveSnapshot == nil {
            return true
        }
        if lastFastFrameHostTime == 0 {
            return true
        }
        let elapsedTicks = hostTime &- lastFastFrameHostTime
        let elapsedSeconds = Double(elapsedTicks) * Self.hostTimeToSecondsFactor
        return elapsedSeconds >= fastFrameSampleInterval
    }

    /// Applies a predicted frame so overlays can move in lockstep with the host window.
    private func applyPredictedFrameIfPossible(leadTime: TimeInterval) {
        guard leadTime > 0 else { return }
        guard let snapshot = cachedActiveSnapshot else { return }
        guard let displayID = activeDisplayID else { return }
        guard overlayWindowsByDisplayID[displayID] != nil else { return }
        let boostedLead = leadTime * predictiveLeadMultiplier(for: leadTime)
        guard let predictedFrame = motionPredictor.predictedFrame(leadTime: boostedLead) else { return }

        let tolerance: CGFloat = 0.18
        if snapshot.frame.isApproximatelyEqual(to: predictedFrame, tolerance: tolerance) {
            if predictedSnapshotsByDisplayID.removeValue(forKey: displayID) != nil {
                applyOverlayMasksFromCache()
            }
            return
        }

        let centerShift = hypot(
            predictedFrame.midX - snapshot.frame.midX,
            predictedFrame.midY - snapshot.frame.midY
        )
        let sizeShift = max(
            abs(predictedFrame.width - snapshot.frame.width),
            abs(predictedFrame.height - snapshot.frame.height)
        )
        if centerShift < minimumPredictionDelta && sizeShift < minimumPredictionDelta {
            if predictedSnapshotsByDisplayID.removeValue(forKey: displayID) != nil {
                applyOverlayMasksFromCache()
            }
            return
        }

        let predictedSnapshot = ActiveWindowSnapshot(
            frame: predictedFrame,
            cornerRadius: snapshot.cornerRadius,
            supplementaryMasks: snapshot.supplementaryMasks
        )
        if predictedSnapshotsByDisplayID[displayID] == predictedSnapshot {
            return
        }
        predictedSnapshotsByDisplayID[displayID] = predictedSnapshot
        applyOverlayMasksFromCache()
    }

    /// Attempts a lightweight position refresh using the CoreGraphics frame list to avoid
    /// reconstructing supplementary mask metadata on every display refresh.
    private func refreshActiveWindowFrameFast() -> FrameRefreshResult {
        let exclusionNumbers = activeOverlayWindowNumbers()
        guard let cgFrame = resolveActiveWindowFrameUsingCoreGraphics(excluding: exclusionNumbers) else {
            return .needsFallback
        }

        guard var cachedSnapshot = cachedActiveSnapshot else {
            motionPredictor.record(frame: cgFrame)
            return .needsFallback
        }

        let tolerance: CGFloat = 0.35
        if cachedSnapshot.frame.isApproximatelyEqual(to: cgFrame, tolerance: tolerance) {
            motionPredictor.record(frame: cgFrame)
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
}

extension OverlayController: OverlayServiceDelegate {
    /// Receives overlay updates from the service and replaces the managed window set.
    func overlayService(_ service: OverlayService, didUpdateOverlays updatedOverlayWindows: [DisplayID: OverlayWindow]) {
        refreshOverlayWindows(updatedOverlayWindows)
    }
}
