// Permissions (TCC):
// - Accessibility: required to retrieve focused window frames.
// - App Store: feature category "system-wide overlays" is often review-sensitive.

import AppKit
import os.log
import QuartzCore
import CoreGraphics
import Cocoa

/// Keeps OverlayWindow instances synchronized with the focused window and display configuration.
@MainActor
final class OverlayController {
    /// Groups the idle and interaction intervals used when polling the focused window.
    private struct PollingCadence {
        let idleInterval: TimeInterval
        let interactionInterval: TimeInterval
        let quiescentInterval: TimeInterval
        let quiescentEntryDelay: TimeInterval

        init(profile: WindowTrackingProfile) {
            self.idleInterval = profile.idleInterval
            self.interactionInterval = profile.interactionInterval
            self.quiescentInterval = profile.quiescentInterval
            self.quiescentEntryDelay = profile.quiescentEntryDelay
        }
    }

    /// Describes a single carve-out request that will be applied to an overlay mask.
    private struct MaskRequest: Equatable {
        let rect: NSRect
        let cornerRadius: CGFloat
        let purpose: ActiveWindowSnapshot.MaskRegion.Purpose?
        let peripheralKind: PeripheralInterfaceRegion.Kind?
        let isSynthesizedPeripheral: Bool

        init(
            rect: NSRect,
            cornerRadius: CGFloat,
            purpose: ActiveWindowSnapshot.MaskRegion.Purpose?,
            peripheralKind: PeripheralInterfaceRegion.Kind? = nil,
            isSynthesizedPeripheral: Bool = false
        ) {
            self.rect = rect
            self.cornerRadius = cornerRadius
            self.purpose = purpose
            self.peripheralKind = peripheralKind
            self.isSynthesizedPeripheral = isSynthesizedPeripheral
        }

        var describesAutoHiddenDock: Bool {
            guard let peripheralKind else { return false }
            if case .dock(_, let isAutoHidden) = peripheralKind {
                return isAutoHidden
            }
            return false
        }

        var describesDock: Bool {
            guard let peripheralKind else { return false }
            if case .dock = peripheralKind {
                return true
            }
            return false
        }

        var requiresAutoHiddenDockAnimation: Bool {
            describesAutoHiddenDock
        }

        static func == (lhs: MaskRequest, rhs: MaskRequest) -> Bool {
            lhs.rect.isApproximatelyEqual(to: rhs.rect, tolerance: 0.05) &&
            abs(lhs.cornerRadius - rhs.cornerRadius) <= 0.05 &&
            lhs.purpose == rhs.purpose &&
            lhs.peripheralKind == rhs.peripheralKind &&
            lhs.isSynthesizedPeripheral == rhs.isSynthesizedPeripheral
        }
    }

    private struct BackgroundWindowSnapshot {
        let windowNumber: Int
        let ownerPID: pid_t?
        let snapshot: ActiveWindowSnapshot
        let timestamp: Date
    }

    private struct DisplaySnapshotCacheEntry {
        var snapshot: ActiveWindowSnapshot
        var timestamp: Date
        var maskRegions: [OverlayWindow.MaskRegion]
    }

    private struct MaskRegionBuildCacheEntry {
        let fingerprint: Int
        let windowFrame: NSRect
        let contentBounds: NSRect
        let backingScale: CGFloat
        let regions: [OverlayWindow.MaskRegion]
        let timestamp: Date
    }

    private struct DisplaySnapshotCache {
        var entries: [WindowIdentity: DisplaySnapshotCacheEntry] = [:]
        var lastIdentity: WindowIdentity?

        mutating func recordSnapshot(
            _ snapshot: ActiveWindowSnapshot,
            identity: WindowIdentity,
            timestamp: Date,
            limit: Int
        ) {
            var entry = entries[identity] ?? DisplaySnapshotCacheEntry(
                snapshot: snapshot,
                timestamp: timestamp,
                maskRegions: []
            )
            entry.snapshot = snapshot
            entry.timestamp = timestamp
            entries[identity] = entry
            lastIdentity = identity
            enforceLimit(limit)
        }

        mutating func updateMaskRegions(
            _ regions: [OverlayWindow.MaskRegion],
            for identity: WindowIdentity,
            timestamp: Date
        ) {
            guard var entry = entries[identity] else { return }
            entry.maskRegions = regions
            entry.timestamp = timestamp
            entries[identity] = entry
            lastIdentity = identity
        }

        mutating func touch(identity: WindowIdentity, timestamp: Date) {
            guard var entry = entries[identity] else { return }
            entry.timestamp = timestamp
            entries[identity] = entry
            lastIdentity = identity
        }

        func entry(for identity: WindowIdentity) -> DisplaySnapshotCacheEntry? {
            entries[identity]
        }

        mutating func removeEntry(for identity: WindowIdentity) {
            entries.removeValue(forKey: identity)
            if lastIdentity == identity {
                lastIdentity = entries.max(by: { $0.value.timestamp < $1.value.timestamp })?.key
            }
        }

        mutating func prune(olderThan cutoff: Date, limit: Int) {
            entries = entries.filter { $0.value.timestamp >= cutoff }
            if let identity = lastIdentity, entries[identity] == nil {
                lastIdentity = entries.max(by: { $0.value.timestamp < $1.value.timestamp })?.key
            }
            enforceLimit(limit)
        }

        mutating func enforceLimit(_ limit: Int) {
            guard entries.count > limit else { return }
            let sorted = entries.sorted { $0.value.timestamp > $1.value.timestamp }
            entries = Dictionary(uniqueKeysWithValues: sorted.prefix(limit).map { ($0.key, $0.value) })
            if let identity = lastIdentity, entries[identity] == nil {
                lastIdentity = sorted.first?.key
            }
        }

        func preferredEntry() -> (WindowIdentity, DisplaySnapshotCacheEntry)? {
            if let identity = lastIdentity, let entry = entries[identity] {
                return (identity, entry)
            }
            return entries.max(by: { $0.value.timestamp < $1.value.timestamp })
        }

        func mostRecentMaskEntry(excluding identity: WindowIdentity?) -> DisplaySnapshotCacheEntry? {
            return entries
                .filter { $0.key != identity && !$0.value.maskRegions.isEmpty }
                .max(by: { $0.value.timestamp < $1.value.timestamp })?.value
        }

        var isEmpty: Bool {
            entries.isEmpty
        }
    }

    private struct SleepPreservationState {
        let activeSnapshot: ActiveWindowSnapshot?
        let cachedSnapshots: [DisplayID: DisplaySnapshotCache]
        let activeDisplayID: DisplayID?
        let timestamp: Date
    }

    private struct WindowIdentity: Hashable {
        let ownerPID: pid_t?
        let windowNumber: Int?
        private let fallbackSignature: Int

        init(snapshot: ActiveWindowSnapshot) {
            self.ownerPID = snapshot.ownerPID
            self.windowNumber = snapshot.windowNumber
            if snapshot.windowNumber != nil {
                fallbackSignature = 0
            } else {
                fallbackSignature = WindowIdentity.signature(for: snapshot.frame)
            }
        }

        init(ownerPID: pid_t?, windowNumber: Int?) {
            self.ownerPID = ownerPID
            self.windowNumber = windowNumber
            self.fallbackSignature = 0
        }

        private static func signature(for frame: NSRect) -> Int {
            let scale: CGFloat = 100
            let components = [
                Int(frame.origin.x * scale),
                Int(frame.origin.y * scale),
                Int(frame.size.width * scale),
                Int(frame.size.height * scale)
            ]
            return components.reduce(5381) { acc, value in
                (acc &* 33) ^ value
            }
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ownerPID ?? 0)
            hasher.combine(windowNumber ?? 0)
            hasher.combine(fallbackSignature)
        }

        static func == (lhs: WindowIdentity, rhs: WindowIdentity) -> Bool {
            lhs.ownerPID == rhs.ownerPID &&
            lhs.windowNumber == rhs.windowNumber &&
            lhs.fallbackSignature == rhs.fallbackSignature
        }
    }

    private let interactionBoostDuration: TimeInterval = 0.6
    private let interactionCooldownDuration: TimeInterval = 0.25
    private let animationBoostDuration: TimeInterval = 0.45
    private let displaySnapshotRetentionInterval: TimeInterval = 5 * 60
    private let maxSnapshotsPerDisplay = 4
    private let maskRegionBuildCacheLifetime: TimeInterval = 2.2
    private let simplifiedMaskModeDuration: TimeInterval = 6
    private let maskSimplificationActivationFallbackRatio: Double = 0.55
    private let maskSimplificationMinimumFrames: UInt64 = 120
    private let maximumSupplementaryRequests = 14
    private let maximumSupplementaryRequestsDuringSimplification = 6
    private let maximumPeripheralRequestsDuringSimplification = 2
    private let activeWindowSnapshotResolver: (Set<Int>, Bool) -> ActiveWindowSnapshot?
    private let defaultMinimumPredictionDelta: CGFloat = 0.32
    private let defaultPredictiveLeadCompensationFraction: Double = 0.22
    private var minimumPredictionDelta: CGFloat = 0.32
    private var predictiveLeadCompensationFraction: Double = 0.35

    private var overlayWindowsByDisplayID: [DisplayID: OverlayWindow] = [:]
    private var snapshotPollingTimer: Timer?
    private var currentTrackingProfile: WindowTrackingProfile
    private var currentPollingCadence: PollingCadence
    private var currentPollingInterval: TimeInterval
    private var interactionBoostExpiration: Date?
    private var isClickThroughEnabled = true
    private var isMonitoringActive = false
    private var cachedActiveSnapshot: ActiveWindowSnapshot?
    private var cachedSnapshotsByDisplayID: [DisplayID: DisplaySnapshotCache] = [:]
    private var predictedSnapshotsByDisplayID: [DisplayID: ActiveWindowSnapshot] = [:]
    private var activeSnapshotDisplayIDs: Set<DisplayID> = []
    private var activeDisplayID: DisplayID?
    private var pointerInteractionMonitor: PointerInteractionMonitor?
    private var pointerHoverMonitor: PointerHoverMonitor?
    private var lastPointerLocation: NSPoint?
    private var lastPointerDragSample: (location: NSPoint, timestamp: CFTimeInterval)?
    private var pointerDisplayIDHint: DisplayID?
    private var workspaceAnimationObservers: [NSObjectProtocol] = []
    private var powerObservers: [NSObjectProtocol] = []
    private var peripheralMaskRequestsByDisplayID: [DisplayID: [MaskRequest]] = [:]
    private var frozenMaskRegionsByDisplayID: [DisplayID: [OverlayWindow.MaskRegion]] = [:]
    private var cachedPeripheralRegions: [PeripheralInterfaceRegion] = []
    private var lastPeripheralRegionRefresh = Date.distantPast
    private let peripheralRegionCacheLifetime: TimeInterval = 0.25
    private let defaultPeripheralAnimationInterval: TimeInterval = 1.0 / 60.0
    private var resolvedPeripheralAnimationInterval: TimeInterval = 1.0 / 60.0
    private var activePeripheralAnimationInterval: TimeInterval?
    private let autoHiddenDockEdgeContactTolerance: CGFloat = 4
    private var peripheralAnimationTimer: Timer?
    private var isDesktopPeripheralRevealEnabled = true
    private let desktopRevealEvaluationInterval: TimeInterval = 0.35
    private var lastDesktopRevealEvaluation = Date.distantPast
    private var cachedDesktopRevealDecision = false
    private var cachedDesktopRevealProcessID: pid_t?
    private let defaultPointerPredictionMinimumMovement: CGFloat = 0.45
    private var pointerPredictionMinimumMovement: CGFloat = 0.45
    private var requiresContinuousPrediction = false
    private lazy var supplementalSnapshotDisplayLink = DisplayLinkDriver { [weak self] timing in
        guard let self else { return }
        self.handleDisplayLinkTick(timing: timing)
    }
    private var isDisplayLinkRunning = false
    private var lastDisplayLinkRefreshInterval: TimeInterval = 1.0 / 60.0
    private let motionPredictor = WindowMotionPredictor()
    private var fastFrameSampleInterval: TimeInterval
    private let defaultFastFrameSamplingBounds: (minimum: TimeInterval, maximum: TimeInterval)
    private var fastFrameSamplingBounds: (minimum: TimeInterval, maximum: TimeInterval)
    private var lastFastFrameHostTime: UInt64 = 0
    private static let hostTimeToSecondsFactor: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        let nanosecondsPerTick = Double(info.numer) / Double(info.denom)
        return nanosecondsPerTick / 1_000_000_000.0
    }()
    private var nextMaskDiagnosticsLogDate = Date.distantPast
    private var lastMaskApplicationDate = Date.distantPast
    private let maskDiagnosticsLogger = Logger(subsystem: "com.focusly.app", category: "OverlayMask")
    private var defaultApplicationMaskingMode: ApplicationMaskingMode = .allApplicationWindows
    private var maskingModeOverrides: [DisplayID: ApplicationMaskingMode] = [:]
    private var isApplicationWideSnapshotEnabled = true
    private var lastImmediateSnapshotRefresh = Date.distantPast
    private let immediateSnapshotRefreshCooldown: TimeInterval = 1.0 / 90.0
    private var resolvedImmediateSnapshotCooldown: TimeInterval = 1.0 / 90.0
    private var quiescentDeadline = Date.distantPast
    private var isInQuiescentMode = false
    private let pollingTimerToleranceFraction: Double = 0.45
    private let minimumPollingTimerTolerance: TimeInterval = 0.0025
    private let maximumPollingTimerTolerance: TimeInterval = 0.75
    private var displayRefreshProfiles: [DisplayID: DisplayRefreshProfile] = [:]
    private let isSecondGenerationAppleSilicon = HardwareCapabilities.isSecondGenerationAppleSilicon
    private let isThirdGenerationAppleSilicon = HardwareCapabilities.isThirdGenerationAppleSilicon
    private let supportsHighRefreshCompositing = HardwareCapabilities.supportsHighRefreshCompositing
    private let supportsPointerDrivenInteractionBoosts = HardwareCapabilities.supportsPointerDrivenInteractionBoosts
    private let maximumPredictionLeadTime: TimeInterval
    private var shouldBiasPredictionsOneFrameAhead = false
    private var preferredPredictionFrameInterval: TimeInterval = 0
    private var highFrequencyPointerSampler: HighFrequencyPointerSampler?
    private var lastPerformanceTuningDisplayID: DisplayID?
    private var isDisplayLinkPinnedByRefreshProfile = false
    private let defaultPredictionIdleSuppressionInterval: TimeInterval = 0.25
    private var predictionIdleSuppressionInterval: TimeInterval = 0.25
    private var backgroundSnapshotEntries: [BackgroundWindowSnapshot] = []
    private let backgroundSnapshotLifetime: TimeInterval = 4
    private let backgroundSnapshotLimit = 6
    private let backgroundSnapshotRefreshInterval: TimeInterval = 0.35
    private var lastBackgroundSnapshotRefresh = Date.distantPast
    private var lastSnapshotIdentity: WindowIdentity?
    private var sleepPreservationState: SleepPreservationState?
    private var maskRegionBuildCacheByDisplayID: [DisplayID: MaskRegionBuildCacheEntry] = [:]
    private var simplifiedMaskModeUntil = Date.distantPast

    init(
        activeWindowSnapshotResolver: @escaping (Set<Int>, Bool) -> ActiveWindowSnapshot? = { windowNumbers, includeApplicationWindows in
            resolveActiveWindowSnapshot(excluding: windowNumbers, includeAllApplicationWindows: includeApplicationWindows)
        }
    ) {
        self.activeWindowSnapshotResolver = activeWindowSnapshotResolver
        self.currentTrackingProfile = .standard
        self.currentPollingCadence = PollingCadence(profile: .standard)
        self.currentPollingInterval = currentPollingCadence.idleInterval
        if supportsHighRefreshCompositing {
            self.defaultFastFrameSamplingBounds = (minimum: 1.0 / 360.0, maximum: 1.0 / 36.0)
            self.fastFrameSampleInterval = 1.0 / 90.0
        } else {
            self.defaultFastFrameSamplingBounds = (minimum: 1.0 / 240.0, maximum: 1.0 / 45.0)
            self.fastFrameSampleInterval = 1.0 / 75.0
        }
        self.fastFrameSamplingBounds = defaultFastFrameSamplingBounds
        self.maximumPredictionLeadTime = isThirdGenerationAppleSilicon ? (1.0 / 16.0) : (1.0 / 18.0)
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
        startWorkspaceAnimationMonitoring()
        startPowerMonitoring()
        capturePointerDisplayHintFromSystem()
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
        stopWorkspaceAnimationMonitoring()
        stopPowerMonitoring()
        stopDisplayLinkIfNeeded()
        isDisplayLinkPinnedByRefreshProfile = false
        cachedActiveSnapshot = nil
        cachedSnapshotsByDisplayID.removeAll()
        predictedSnapshotsByDisplayID.removeAll()
        activeDisplayID = nil
        frozenMaskRegionsByDisplayID.removeAll()
        pointerDisplayIDHint = nil
        motionPredictor.reset()
        lastSnapshotIdentity = nil
        backgroundSnapshotEntries.removeAll()
        lastBackgroundSnapshotRefresh = .distantPast
        maskRegionBuildCacheByDisplayID.removeAll()
        simplifiedMaskModeUntil = .distantPast
        updateDisplayLinkPreferredDisplay()
        updateDisplayPerformanceHints(forceRefresh: true)
        requiresContinuousPrediction = false
        pointerPredictionMinimumMovement = defaultPointerPredictionMinimumMovement
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
        let targetInterval: TimeInterval
        if isInQuiescentMode {
            targetInterval = max(currentPollingCadence.quiescentInterval, 0.01)
        } else {
            targetInterval = desiredIntervalForCurrentInteractionState()
        }
        currentPollingInterval = targetInterval
        resetQuiescentDeadline()
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
            lastSnapshotIdentity = nil
            updateDisplayLinkPreferredDisplay()
            updateDisplayPerformanceHints()
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
        resetDesktopRevealEvaluation()
        rebuildPeripheralHoverState()
    }

    /// Replaces the overlay window map, cleaning up removed displays and applying cached masks.
    func refreshOverlayWindows(_ updatedOverlayWindows: [DisplayID: OverlayWindow]) {
        let previousOverlayWindows = overlayWindowsByDisplayID
        overlayWindowsByDisplayID = updatedOverlayWindows

        let removedDisplayIDs = Set(previousOverlayWindows.keys).subtracting(updatedOverlayWindows.keys)
        for displayID in removedDisplayIDs {
            previousOverlayWindows[displayID]?.applyMask(regions: [])
            maskRegionBuildCacheByDisplayID.removeValue(forKey: displayID)
        }

        let updatedDisplayIDs = Set(updatedOverlayWindows.keys)
        pruneCachesToActiveOverlays()
        activeSnapshotDisplayIDs = activeSnapshotDisplayIDs.intersection(updatedDisplayIDs)
        var didMutateActiveDisplay = false
        if let activeID = activeDisplayID, !updatedDisplayIDs.contains(activeID) {
            activeDisplayID = nil
            didMutateActiveDisplay = true
        }

        overlayWindowsByDisplayID.values.forEach { $0.setClickThrough(isClickThroughEnabled) }

        if let snapshot = cachedActiveSnapshot {
            rebuildDisplayScopedSnapshotCache(for: snapshot)
        }

        if isMonitoringActive {
            applyCachedOverlayMask()
        }
        if didMutateActiveDisplay {
            updateDisplayLinkPreferredDisplay()
        }
        updateDisplayPerformanceHints()
        updateApplicationWideSnapshotFlag()
        refreshPeripheralRegionsIfNeeded(force: true)
        updatePeripheralHoverState(for: NSEvent.mouseLocation)
    }

    /// Applies the supplied snapshot to all overlays, carving out the focused window and related UI.
    func applyOverlayMask(with snapshot: ActiveWindowSnapshot?) {
        guard let snapshot else {
            cachedActiveSnapshot = nil
            predictedSnapshotsByDisplayID.removeAll()
            activeDisplayID = nil
            activeSnapshotDisplayIDs = []
            motionPredictor.reset()
            updateDisplayLinkPreferredDisplay()
            updateDisplayPerformanceHints()
            resetDesktopRevealEvaluation()
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
        resetQuiescentDeadline()
    }

    /// Stops the polling timer.
    private func stopPolling() {
        snapshotPollingTimer?.invalidate()
        snapshotPollingTimer = nil
        currentPollingInterval = currentPollingCadence.idleInterval
        isInQuiescentMode = false
        quiescentDeadline = .distantPast
    }

    /// Defers the next quiescent evaluation when fresh activity has been observed.
    private func resetQuiescentDeadline() {
        let delay = max(currentPollingCadence.quiescentEntryDelay, 0.1)
        quiescentDeadline = Date().addingTimeInterval(delay)
    }

    /// Switches to the ultra-low-power cadence when overlays have been idle.
    private func enterQuiescentMode() {
        guard !isInQuiescentMode else { return }
        isInQuiescentMode = true
        stopDisplayLinkIfNeeded()
        let interval = max(currentPollingCadence.quiescentInterval, 0.01)
        updatePollingIntervalIfNeeded(interval)
    }

    /// Returns to the normal idle cadence and delays quiescent re-entry.
    private func exitQuiescentModeIfNeeded() {
        guard isInQuiescentMode else {
            resetQuiescentDeadline()
            return
        }
        isInQuiescentMode = false
        resetQuiescentDeadline()
        updatePollingIntervalIfNeeded(desiredIntervalForCurrentInteractionState())
    }

    /// Checks whether the controller should downshift into quiescent mode.
    private func evaluateQuiescentModeIfNeeded() {
        guard !isInQuiescentMode else { return }
        guard quiescentDeadline != .distantPast else { return }
        if Date() >= quiescentDeadline {
            enterQuiescentMode()
        }
    }

    /// Reapplies the last known snapshot so new overlay windows pick up current carve-outs.
    private func applyCachedOverlayMask() {
        applyOverlayMasksFromCache()
    }

    /// Keeps the display-link driver in sync with the display being actively carved out.
    private func updateDisplayLinkPreferredDisplay() {
        let preferredDisplay = activeDisplayID ?? pointerDisplayIDHint
        supplementalSnapshotDisplayLink.setPreferredDisplayID(preferredDisplay)
    }

    /// Refreshes display profiles and retunes prediction parameters for the active display.
    private func updateDisplayPerformanceHints(forceRefresh: Bool = false) {
        let controllingDisplayID = activeDisplayID ?? pointerDisplayIDHint
        if forceRefresh || controllingDisplayID != lastPerformanceTuningDisplayID {
            refreshDisplayRefreshProfiles()
            lastPerformanceTuningDisplayID = controllingDisplayID
        } else if let controllingDisplayID, displayRefreshProfiles[controllingDisplayID] == nil {
            refreshDisplayRefreshProfiles()
        }

        guard let profile = activeRefreshProfile() else {
            lastPerformanceTuningDisplayID = nil
            minimumPredictionDelta = defaultMinimumPredictionDelta
            predictiveLeadCompensationFraction = defaultPredictiveLeadCompensationFraction
            fastFrameSamplingBounds = defaultFastFrameSamplingBounds
            resolvedImmediateSnapshotCooldown = immediateSnapshotRefreshCooldown
            shouldBiasPredictionsOneFrameAhead = false
            preferredPredictionFrameInterval = 0
            predictionIdleSuppressionInterval = defaultPredictionIdleSuppressionInterval
            fastFrameSampleInterval = min(
                max(fastFrameSampleInterval, fastFrameSamplingBounds.minimum),
                fastFrameSamplingBounds.maximum
            )
            updateDisplayLinkPersistence(profile: nil)
            resolvedPeripheralAnimationInterval = defaultPeripheralAnimationInterval
            refreshPeripheralAnimationTimerIfNeeded()
            requiresContinuousPrediction = false
            applyPointerSamplingConfiguration(for: nil)
            return
        }

        let preferredFPS = profile.preferredFramesPerSecond
        shouldBiasPredictionsOneFrameAhead = profile.wantsFrameAheadPrediction
        preferredPredictionFrameInterval = profile.recommendedPredictionLead
        requiresContinuousPrediction = profile.demandsContinuousPrediction
        var idleSuppression = defaultPredictionIdleSuppressionInterval
        if preferredFPS >= 165 {
            minimumPredictionDelta = supportsHighRefreshCompositing ? 0.08 : 0.09
            predictiveLeadCompensationFraction = supportsHighRefreshCompositing ? 0.95 : 0.85
            fastFrameSamplingBounds = (minimum: 1.0 / 480.0, maximum: 1.0 / 26.0)
            idleSuppression = 0.15
            if isThirdGenerationAppleSilicon {
                resolvedImmediateSnapshotCooldown = 1.0 / 360.0
            } else if isSecondGenerationAppleSilicon {
                resolvedImmediateSnapshotCooldown = 1.0 / 320.0
            } else {
                resolvedImmediateSnapshotCooldown = 1.0 / 210.0
            }
        } else if preferredFPS >= 120 {
            minimumPredictionDelta = 0.12
            predictiveLeadCompensationFraction = supportsHighRefreshCompositing ? 0.85 : 0.7
            fastFrameSamplingBounds = (minimum: 1.0 / 360.0, maximum: 1.0 / 30.0)
            idleSuppression = supportsHighRefreshCompositing ? 0.17 : 0.2
            if isThirdGenerationAppleSilicon {
                resolvedImmediateSnapshotCooldown = 1.0 / 300.0
            } else if isSecondGenerationAppleSilicon {
                resolvedImmediateSnapshotCooldown = 1.0 / 260.0
            } else {
                resolvedImmediateSnapshotCooldown = 1.0 / 190.0
            }
        } else if preferredFPS >= 90 {
            minimumPredictionDelta = 0.18
            predictiveLeadCompensationFraction = 0.5
            fastFrameSamplingBounds = (minimum: 1.0 / 300.0, maximum: 1.0 / 36.0)
            idleSuppression = 0.22
            resolvedImmediateSnapshotCooldown = 1.0 / 165.0
        } else {
            minimumPredictionDelta = defaultMinimumPredictionDelta
            predictiveLeadCompensationFraction = defaultPredictiveLeadCompensationFraction
            fastFrameSamplingBounds = defaultFastFrameSamplingBounds
            resolvedImmediateSnapshotCooldown = immediateSnapshotRefreshCooldown
            shouldBiasPredictionsOneFrameAhead = false
            preferredPredictionFrameInterval = 0
            idleSuppression = defaultPredictionIdleSuppressionInterval
        }

        predictionIdleSuppressionInterval = idleSuppression
        if supportsHighRefreshCompositing, preferredFPS >= 120 {
            shouldBiasPredictionsOneFrameAhead = true
            preferredPredictionFrameInterval = max(preferredPredictionFrameInterval, profile.preferredFrameInterval)
        }

        if profile.isBuiltIn, HardwareCapabilities.isAppleSilicon {
            shouldBiasPredictionsOneFrameAhead = true
            preferredPredictionFrameInterval = max(preferredPredictionFrameInterval, profile.preferredFrameInterval)
            predictionIdleSuppressionInterval = min(predictionIdleSuppressionInterval, idleSuppression * 0.8)
            if isThirdGenerationAppleSilicon {
                fastFrameSamplingBounds = (
                    minimum: min(fastFrameSamplingBounds.minimum, 1.0 / 420.0),
                    maximum: fastFrameSamplingBounds.maximum
                )
                resolvedImmediateSnapshotCooldown = min(resolvedImmediateSnapshotCooldown, 1.0 / 260.0)
            }
        }

        fastFrameSampleInterval = min(
            max(fastFrameSampleInterval, fastFrameSamplingBounds.minimum),
            fastFrameSamplingBounds.maximum
        )
        updateDisplayLinkPersistence(profile: profile)
        resolvedPeripheralAnimationInterval = peripheralAnimationInterval(for: profile)
        refreshPeripheralAnimationTimerIfNeeded()
        applyPointerSamplingConfiguration(for: profile)
    }

    /// Rebuilds known refresh profiles for all connected overlays.
    private func refreshDisplayRefreshProfiles() {
        var updatedProfiles: [DisplayID: DisplayRefreshProfile] = [:]
        for (displayID, overlayWindow) in overlayWindowsByDisplayID where displayID != 0 {
            if let profile = DisplayRefreshEstimator.profile(for: displayID, screen: overlayWindow.screen) {
                updatedProfiles[displayID] = profile
            }
        }
        let interestingDisplayIDs = [activeDisplayID, pointerDisplayIDHint].compactMap { $0 }.filter { $0 != 0 }
        for displayID in interestingDisplayIDs where updatedProfiles[displayID] == nil {
            if let profile = DisplayRefreshEstimator.profile(for: displayID) {
                updatedProfiles[displayID] = profile
            }
        }
        displayRefreshProfiles = updatedProfiles
    }

    /// Returns the refresh profile that should dictate aggressive prediction tuning.
    private func activeRefreshProfile() -> DisplayRefreshProfile? {
        if let activeID = activeDisplayID, let profile = displayRefreshProfiles[activeID] {
            return profile
        }
        if let pointerID = pointerDisplayIDHint, let profile = displayRefreshProfiles[pointerID] {
            return profile
        }
        return nil
    }

    /// Keeps the supplemental display link alive when a display demands tight prediction.
    private func updateDisplayLinkPersistence(profile: DisplayRefreshProfile?) {
        let shouldPin = isMonitoringActive && (profile?.prefersPersistentDisplayLink == true)
        if shouldPin {
            guard !isDisplayLinkPinnedByRefreshProfile else { return }
            isDisplayLinkPinnedByRefreshProfile = true
            startDisplayLinkIfNeeded()
            return
        }

        guard isDisplayLinkPinnedByRefreshProfile else { return }
        isDisplayLinkPinnedByRefreshProfile = false
        if interactionBoostExpiration == nil {
            stopDisplayLinkIfNeeded()
        }
    }

    /// Applies pointer sampling thresholds tailored to the current display profile.
    private func applyPointerSamplingConfiguration(for profile: DisplayRefreshProfile?) {
        let thresholds = pointerSamplingThresholds(for: profile)
        highFrequencyPointerSampler?.updateMinimumMovementDistance(thresholds.idle, dragDistance: thresholds.drag)
        pointerPredictionMinimumMovement = pointerPredictionThreshold(for: profile)
    }

    /// Returns the pointer sampling distance thresholds to use for a given refresh profile.
    private func pointerSamplingThresholds(for profile: DisplayRefreshProfile?) -> (idle: CGFloat, drag: CGFloat) {
        guard let profile else { return (0.35, 0) }
        if profile.preferredFramesPerSecond >= 165 {
            return (0.12, 0)
        }
        if profile.preferredFramesPerSecond >= 144 {
            return (0.15, 0)
        }
        if profile.preferredFramesPerSecond >= 120 {
            return (0.18, 0)
        }
        if profile.preferredFramesPerSecond >= 90 {
            return (0.25, 0)
        }
        return (0.35, 0)
    }

    /// Keeps the pointer prediction jitter threshold in sync with the active display.
    private func pointerPredictionThreshold(for profile: DisplayRefreshProfile?) -> CGFloat {
        guard let profile else { return defaultPointerPredictionMinimumMovement }
        let fps = profile.preferredFramesPerSecond
        if fps >= 165 {
            return isThirdGenerationAppleSilicon ? 0.1 : 0.14
        }
        if fps >= 144 {
            return isThirdGenerationAppleSilicon ? 0.13 : 0.17
        }
        if fps >= 120 {
            if profile.isBuiltIn {
                return isThirdGenerationAppleSilicon ? 0.16 : 0.2
            }
            return 0.22
        }
        if profile.usesVariableRefreshRate && profile.isBuiltIn {
            return 0.24
        }
        if fps >= 90 {
            return 0.32
        }
        return defaultPointerPredictionMinimumMovement
    }

    /// Resolves the cadence the peripheral animation driver should use for the active display.
    private func peripheralAnimationInterval(for profile: DisplayRefreshProfile?) -> TimeInterval {
        guard let profile else { return defaultPeripheralAnimationInterval }
        if profile.isBuiltIn && profile.usesVariableRefreshRate {
            return 1.0 / max(profile.preferredFramesPerSecond, 120)
        }
        if profile.preferredFramesPerSecond >= 165 {
            return 1.0 / min(profile.preferredFramesPerSecond, 240)
        }
        if profile.preferredFramesPerSecond >= 144 {
            return 1.0 / 144.0
        }
        if profile.preferredFramesPerSecond >= 120 {
            return 1.0 / max(profile.preferredFramesPerSecond, 120)
        }
        if profile.preferredFramesPerSecond >= 90 {
            return 1.0 / 90.0
        }
        return defaultPeripheralAnimationInterval
    }

    /// Restarts the peripheral animation timer when the desired interval changes.
    private func refreshPeripheralAnimationTimerIfNeeded() {
        guard peripheralAnimationTimer != nil else {
            activePeripheralAnimationInterval = nil
            return
        }
        guard let currentInterval = activePeripheralAnimationInterval else {
            stopPeripheralAnimationDriver()
            startPeripheralAnimationDriver()
            return
        }
        let delta = abs(currentInterval - resolvedPeripheralAnimationInterval)
        if delta <= 0.0005 {
            return
        }
        stopPeripheralAnimationDriver()
        startPeripheralAnimationDriver()
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
        if diagnostics.totalFrames >= maskSimplificationMinimumFrames,
           fallbackRatio >= maskSimplificationActivationFallbackRatio {
            simplifiedMaskModeUntil = now.addingTimeInterval(simplifiedMaskModeDuration)
        }
        nextMaskDiagnosticsLogDate = now.addingTimeInterval(8)
    }

    /// Updates cached mask metadata for the latest active window snapshot.
    private func cacheActiveSnapshot(_ snapshot: ActiveWindowSnapshot, resolvedDisplayID: DisplayID? = nil) {
        let identity = WindowIdentity(snapshot: snapshot)
        if identity != lastSnapshotIdentity {
            motionPredictor.reset()
            lastSnapshotIdentity = identity
        }
        cachedActiveSnapshot = snapshot
        motionPredictor.record(frame: snapshot.frame)
        resetDesktopRevealEvaluation()

        let resolvedID: DisplayID?
        if let providedID = resolvedDisplayID {
            resolvedID = providedID
        } else {
            resolvedID = resolveDisplayIdentifier(for: snapshot.frame) ?? pointerDisplayIDHint
        }

        if let resolvedID {
            predictedSnapshotsByDisplayID.removeValue(forKey: resolvedID)
            activeDisplayID = resolvedID
        } else if let activeID = activeDisplayID {
            predictedSnapshotsByDisplayID.removeValue(forKey: activeID)
        } else {
            activeDisplayID = nil
            predictedSnapshotsByDisplayID.removeAll()
        }

        rebuildDisplayScopedSnapshotCache(for: snapshot, preferredDisplayID: resolvedID ?? activeDisplayID)

        updateDisplayLinkPreferredDisplay()
        updateDisplayPerformanceHints()
        rebuildPeripheralHoverState()
        primePredictionForCurrentFrameIfNeeded()
    }

    private func pruneCachesToActiveOverlays() {
        guard !overlayWindowsByDisplayID.isEmpty else { return }
        let activeIDs = Set(overlayWindowsByDisplayID.keys)
        cachedSnapshotsByDisplayID = cachedSnapshotsByDisplayID.filter { activeIDs.contains($0.key) }
        predictedSnapshotsByDisplayID = predictedSnapshotsByDisplayID.filter { activeIDs.contains($0.key) }
        frozenMaskRegionsByDisplayID = frozenMaskRegionsByDisplayID.filter { activeIDs.contains($0.key) }
        peripheralMaskRequestsByDisplayID = peripheralMaskRequestsByDisplayID.filter { activeIDs.contains($0.key) }
        maskRegionBuildCacheByDisplayID = maskRegionBuildCacheByDisplayID.filter { activeIDs.contains($0.key) }
        activeSnapshotDisplayIDs = activeSnapshotDisplayIDs.intersection(activeIDs)
        if let activeDisplayID, !activeIDs.contains(activeDisplayID) {
            self.activeDisplayID = nil
        }
    }

    private func rebindActiveSnapshotDisplays(for snapshot: ActiveWindowSnapshot) {
        let resolvedDisplay = resolveDisplayIdentifier(for: snapshot.frame) ?? pointerDisplayIDHint
        if resolvedDisplay != activeDisplayID {
            activeDisplayID = resolvedDisplay
            predictedSnapshotsByDisplayID.removeAll()
            updateDisplayLinkPreferredDisplay()
            updateDisplayPerformanceHints()
        }
        rebuildDisplayScopedSnapshotCache(for: snapshot, preferredDisplayID: resolvedDisplay ?? activeDisplayID)
    }

    private func restorePreservedSnapshotStateIfNeeded() {
        guard let preserved = sleepPreservationState else { return }
        sleepPreservationState = nil
        cachedActiveSnapshot = preserved.activeSnapshot
        cachedSnapshotsByDisplayID = preserved.cachedSnapshots
        activeDisplayID = preserved.activeDisplayID
        predictedSnapshotsByDisplayID.removeAll()
        frozenMaskRegionsByDisplayID.removeAll()
        pruneCachesToActiveOverlays()
        if let snapshot = cachedActiveSnapshot {
            cacheActiveSnapshot(snapshot, resolvedDisplayID: activeDisplayID)
        } else {
            applyOverlayMask(with: nil)
        }
    }

    private func storeSnapshot(
        _ snapshot: ActiveWindowSnapshot,
        identity: WindowIdentity,
        for displayID: DisplayID,
        timestamp: Date
    ) {
        var cache = cachedSnapshotsByDisplayID[displayID] ?? DisplaySnapshotCache()
        cache.recordSnapshot(snapshot, identity: identity, timestamp: timestamp, limit: maxSnapshotsPerDisplay)
        cachedSnapshotsByDisplayID[displayID] = cache
    }

    private func storeMaskRegions(
        _ regions: [OverlayWindow.MaskRegion],
        for displayID: DisplayID,
        identity: WindowIdentity,
        timestamp: Date = Date()
    ) {
        var cache = cachedSnapshotsByDisplayID[displayID] ?? DisplaySnapshotCache()
        cache.updateMaskRegions(regions, for: identity, timestamp: timestamp)
        cachedSnapshotsByDisplayID[displayID] = cache
    }

    private func touchCacheEntry(for displayID: DisplayID, identity: WindowIdentity, timestamp: Date = Date()) {
        guard var cache = cachedSnapshotsByDisplayID[displayID] else { return }
        cache.touch(identity: identity, timestamp: timestamp)
        cachedSnapshotsByDisplayID[displayID] = cache
    }

    private func removeCacheEntry(for displayID: DisplayID, identity: WindowIdentity) {
        guard var cache = cachedSnapshotsByDisplayID[displayID] else { return }
        cache.removeEntry(for: identity)
        if cache.isEmpty {
            cachedSnapshotsByDisplayID.removeValue(forKey: displayID)
        } else {
            cachedSnapshotsByDisplayID[displayID] = cache
        }
    }

    private func preferredCacheEntry(for displayID: DisplayID) -> (WindowIdentity, DisplaySnapshotCacheEntry)? {
        cachedSnapshotsByDisplayID[displayID]?.preferredEntry()
    }

    /// Rebuilds the per-display snapshot cache so each monitor only receives relevant carve-outs.
    private func rebuildDisplayScopedSnapshotCache(
        for snapshot: ActiveWindowSnapshot,
        preferredDisplayID: DisplayID? = nil
    ) {
        let now = Date()
        pruneExpiredDisplaySnapshots(referenceDate: now)
        let fallbackDisplayID = preferredDisplayID ?? activeDisplayID
        var snapshotDisplayIDs: Set<DisplayID> = []
        guard !overlayWindowsByDisplayID.isEmpty else {
            if let fallbackDisplayID {
                cachedSnapshotsByDisplayID.removeAll()
                let identity = WindowIdentity(snapshot: snapshot)
                storeSnapshot(snapshot, identity: identity, for: fallbackDisplayID, timestamp: now)
                snapshotDisplayIDs.insert(fallbackDisplayID)
            } else {
                cachedSnapshotsByDisplayID.removeAll()
            }
            activeSnapshotDisplayIDs = snapshotDisplayIDs
            return
        }

        let identity = WindowIdentity(snapshot: snapshot)
        var didUpdateAnyPrimaryDisplay = false
        for (displayID, overlayWindow) in overlayWindowsByDisplayID {
            guard snapshotPrimaryFrameIntersectsDisplay(snapshot, displayFrame: overlayWindow.frame) else { continue }
            storeSnapshot(snapshot, identity: identity, for: displayID, timestamp: now)
            didUpdateAnyPrimaryDisplay = true
            snapshotDisplayIDs.insert(displayID)
        }

        if !didUpdateAnyPrimaryDisplay, let fallbackDisplayID {
            storeSnapshot(snapshot, identity: identity, for: fallbackDisplayID, timestamp: now)
            snapshotDisplayIDs.insert(fallbackDisplayID)
        }

        activeSnapshotDisplayIDs = snapshotDisplayIDs

        // Prune any displays that no longer meaningfully intersect the snapshot.
        for displayID in cachedSnapshotsByDisplayID.keys {
            guard let window = overlayWindowsByDisplayID[displayID] else {
                cachedSnapshotsByDisplayID.removeValue(forKey: displayID)
                continue
            }
            if !snapshotMeaningfullyIntersectsWindow(snapshot, windowFrame: window.frame) {
                cachedSnapshotsByDisplayID.removeValue(forKey: displayID)
                frozenMaskRegionsByDisplayID.removeValue(forKey: displayID)
                predictedSnapshotsByDisplayID.removeValue(forKey: displayID)
                snapshotDisplayIDs.remove(displayID)
            }
        }
        activeSnapshotDisplayIDs = snapshotDisplayIDs
    }

    private func pruneExpiredDisplaySnapshots(referenceDate: Date = Date()) {
        guard !cachedSnapshotsByDisplayID.isEmpty else { return }
        let cutoff = referenceDate.addingTimeInterval(-displaySnapshotRetentionInterval)
        cachedSnapshotsByDisplayID = cachedSnapshotsByDisplayID.compactMapValues { cache in
            var mutableCache = cache
            mutableCache.prune(olderThan: cutoff, limit: maxSnapshotsPerDisplay)
            return mutableCache.isEmpty ? nil : mutableCache
        }
    }

    /// Returns whether a snapshot intersects a particular display's bounds.
    private func snapshotPrimaryFrameIntersectsDisplay(_ snapshot: ActiveWindowSnapshot, displayFrame: NSRect) -> Bool {
        let intersection = snapshot.frame.intersection(displayFrame)
        guard !intersection.isNull else { return false }
        let snapshotArea = max(snapshot.frame.width * snapshot.frame.height, .ulpOfOne)
        let overlapArea = intersection.width * intersection.height
        let overlapRatio = overlapArea / snapshotArea
        // Require meaningful overlap so masks detach promptly when crossing displays.
        if overlapRatio >= 0.12 { return true }
        // Still allow small windows if they’re mostly within the display.
        let minDimension: CGFloat = 72
        return intersection.width >= minDimension && intersection.height >= minDimension
    }

    private func snapshotMeaningfullyIntersectsWindow(_ snapshot: ActiveWindowSnapshot, windowFrame: NSRect) -> Bool {
        let intersection = snapshot.frame.intersection(windowFrame)
        guard !intersection.isNull else { return false }
        let overlapArea = intersection.width * intersection.height
        let snapshotArea = max(snapshot.frame.width * snapshot.frame.height, .ulpOfOne)
        let ratio = overlapArea / snapshotArea
        if ratio >= 0.1 { return true }
        let minDimension: CGFloat = 64
        return intersection.width >= minDimension && intersection.height >= minDimension
    }

    /// Applies cached highlight regions to every overlay window.
    private func applyOverlayMasksFromCache() {
        guard !overlayWindowsByDisplayID.isEmpty else { return }
        let now = Date()
        pruneExpiredDisplaySnapshots(referenceDate: now)

        // Proactively clear displays that no longer host the active snapshot.
        let inactiveDisplays = overlayWindowsByDisplayID.keys.filter { !activeSnapshotDisplayIDs.contains($0) }
        for displayID in inactiveDisplays {
            predictedSnapshotsByDisplayID.removeValue(forKey: displayID)
            cachedSnapshotsByDisplayID.removeValue(forKey: displayID)
            frozenMaskRegionsByDisplayID.removeValue(forKey: displayID)
            maskRegionBuildCacheByDisplayID.removeValue(forKey: displayID)
            overlayWindowsByDisplayID[displayID]?.applyMask(regions: [], animated: shouldAnimateMaskTransition(for: displayID))
        }

        var didApplyMask = false
        var staleEntries: [(DisplayID, WindowIdentity)] = []
        var didMutateActiveDisplay = false

        for (displayID, window) in overlayWindowsByDisplayID {
            let animate = shouldAnimateMaskTransition(for: displayID)
            let displayIsActiveForSnapshot = activeSnapshotDisplayIDs.contains(displayID)
            let activeSnapshotIntersected = cachedActiveSnapshot.flatMap { snapshotMeaningfullyIntersectsWindow($0, windowFrame: window.frame) } ?? false
            var applied = false
            var shouldPreserveFrozenMask = false
            var cachedSnapshotEntry: (WindowIdentity, DisplaySnapshotCacheEntry)?
            var ignoredCacheIdentity: WindowIdentity?

            if let predictedSnapshot = predictedSnapshotsByDisplayID[displayID] {
                if window.frame.intersection(predictedSnapshot.frame).isNull {
                    predictedSnapshotsByDisplayID.removeValue(forKey: displayID)
                } else if apply(snapshot: predictedSnapshot, to: window, displayID: displayID, cacheIdentity: nil, animated: false) {
                    didApplyMask = true
                    applied = true
                } else {
                    predictedSnapshotsByDisplayID.removeValue(forKey: displayID)
                }
            }

            if !applied, let entry = preferredCacheEntry(for: displayID) {
                cachedSnapshotEntry = entry
                let (identity, cachedEntry) = entry
                if window.frame.intersection(cachedEntry.snapshot.frame).isNull {
                    staleEntries.append((displayID, identity))
                    continue
                }
                if apply(snapshot: cachedEntry.snapshot, to: window, displayID: displayID, cacheIdentity: identity, animated: animate) {
                    didApplyMask = true
                    applied = true
                    predictedSnapshotsByDisplayID.removeValue(forKey: displayID)
                } else {
                    if !cachedEntry.maskRegions.isEmpty {
                        window.applyMask(regions: cachedEntry.maskRegions, animated: animate)
                        frozenMaskRegionsByDisplayID[displayID] = cachedEntry.maskRegions
                        touchCacheEntry(for: displayID, identity: identity, timestamp: now)
                        didApplyMask = true
                        applied = true
                        shouldPreserveFrozenMask = true
                    } else {
                        staleEntries.append((displayID, identity))
                        ignoredCacheIdentity = identity
                        cachedSnapshotEntry = nil
                    }
                }
            }

            if !applied {
                let frozenMask = lastKnownMaskRegions(
                    for: displayID,
                    cachedEntry: cachedSnapshotEntry?.1,
                    ignoring: ignoredCacheIdentity
                )
                if applyActiveSupplementaryMasksIfNeeded(to: window, displayID: displayID, preserving: frozenMask) {
                    didApplyMask = true
                    shouldPreserveFrozenMask = true
                    continue
                }
                if applyPeripheralMasksIfNeeded(to: window, displayID: displayID, preserving: frozenMask) {
                    didApplyMask = true
                    shouldPreserveFrozenMask = true
                    continue
                }
                if let frozenMask, !frozenMask.isEmpty {
                    window.applyMask(regions: frozenMask, animated: animate)
                    didApplyMask = true
                    shouldPreserveFrozenMask = true
                }
            }

            if !applied && (!displayIsActiveForSnapshot || !activeSnapshotIntersected) {
                predictedSnapshotsByDisplayID.removeValue(forKey: displayID)
                cachedSnapshotsByDisplayID.removeValue(forKey: displayID)
                frozenMaskRegionsByDisplayID[displayID] = nil
                maskRegionBuildCacheByDisplayID.removeValue(forKey: displayID)
                window.applyMask(regions: [], animated: animate)
                didApplyMask = true
                continue
            }

            if shouldPreserveFrozenMask == false {
                frozenMaskRegionsByDisplayID[displayID] = nil
            }
        }

        if didApplyMask {
            pruneStaleEntries(staleEntries)
            didMutateActiveDisplay = true
        }

        if didMutateActiveDisplay {
            lastMaskApplicationDate = now
        }

        evaluateMaskRenderingDiagnosticsIfNeeded()

        if !didApplyMask,
           cachedSnapshotsByDisplayID.isEmpty,
           cachedActiveSnapshot == nil,
           peripheralMaskRequestsByDisplayID.isEmpty {
            overlayWindowsByDisplayID.values.forEach { $0.applyMask(regions: []) }
        }
    }

    private func pruneStaleEntries(_ staleEntries: [(DisplayID, WindowIdentity)]) {
        if staleEntries.isEmpty { return }
        for (displayID, identity) in staleEntries {
            cachedSnapshotsByDisplayID[displayID]?.removeEntry(for: identity)
        }
    }

    /// Converts an active window snapshot into overlay mask regions for the supplied window.
    private func apply(
        snapshot: ActiveWindowSnapshot,
        to window: OverlayWindow,
        displayID: DisplayID,
        cacheIdentity: WindowIdentity? = nil,
        animated: Bool
    ) -> Bool {
        var requests = maskRequests(
            for: snapshot,
            mode: maskingMode(for: displayID),
            window: window,
            displayID: displayID
        )
        if let peripheralRequests = limitedPeripheralRequests(for: displayID), !peripheralRequests.isEmpty {
            requests.append(contentsOf: peripheralRequests)
        }
        if let supplementaryRequests = supplementaryMaskRequestsForActiveSnapshot(
            intersecting: window.frame,
            excluding: snapshot,
            displayID: displayID
        ), !supplementaryRequests.isEmpty {
            requests.append(contentsOf: supplementaryRequests)
        }
        return apply(maskRequests: requests, to: window, cachingDisplayID: displayID, identity: cacheIdentity, animated: animated)
    }

    /// Builds mask requests for the supplied snapshot including supplementary carve-outs.
    private func maskRequests(
        for snapshot: ActiveWindowSnapshot,
        mode: ApplicationMaskingMode,
        window: OverlayWindow,
        displayID: DisplayID
    ) -> [MaskRequest] {
        var requests: [MaskRequest] = []
        guard snapshot.frame.intersects(window.frame) else { return [] }

        requests.append(
            MaskRequest(
                rect: snapshot.frame,
                cornerRadius: snapshot.cornerRadius,
                purpose: .applicationWindow
            )
        )

        let dragActive = motionPredictor.hasRecentSignificantMovement(
            within: 0.2,
            now: CACurrentMediaTime()
        )

        if !snapshot.supplementaryMasks.isEmpty {
            let supplementaryLimit = shouldSimplifyMaskRequests(for: displayID)
                ? maximumSupplementaryRequestsDuringSimplification
                : maximumSupplementaryRequests
            var supplementaryCount = 0
            for region in snapshot.supplementaryMasks {
                if region.purpose == .applicationWindow, mode == .focusedWindow {
                    continue
                }
                if dragActive && region.purpose == .systemMenu {
                    continue
                }
                if region.frame.intersection(window.frame).isNull {
                    continue
                }
                requests.append(
                    MaskRequest(rect: region.frame, cornerRadius: region.cornerRadius, purpose: region.purpose)
                )
                supplementaryCount += 1
                if supplementaryCount >= supplementaryLimit {
                    break
                }
            }
        }

        return requests
    }

    /// Applies supplementary masks from the current active snapshot even if the base snapshot belongs to another display.
    private func supplementaryMaskRequestsForActiveSnapshot(
        intersecting displayFrame: NSRect,
        excluding snapshot: ActiveWindowSnapshot?,
        displayID: DisplayID
    ) -> [MaskRequest]? {
        guard let activeSnapshot = cachedActiveSnapshot else { return nil }
        if let snapshot, snapshot == activeSnapshot {
            return nil
        }
        var requests: [MaskRequest] = []
        let dragActive = motionPredictor.hasRecentSignificantMovement(
            within: 0.2,
            now: CACurrentMediaTime()
        )

        let supplementaryLimit = shouldSimplifyMaskRequests(for: displayID)
            ? maximumSupplementaryRequestsDuringSimplification
            : maximumSupplementaryRequests
        var supplementaryCount = 0
        for region in activeSnapshot.supplementaryMasks where region.purpose != .applicationWindow {
            if dragActive && region.purpose == .systemMenu {
                continue
            }
            if region.frame.intersection(displayFrame).isNull {
                continue
            }
            requests.append(
                MaskRequest(
                    rect: region.frame,
                    cornerRadius: region.cornerRadius,
                    purpose: region.purpose
                )
            )
            supplementaryCount += 1
            if supplementaryCount >= supplementaryLimit {
                break
            }
        }
        return requests.isEmpty ? nil : requests
    }

    /// Applies supplementary masks from the active snapshot when no cached window highlight is available.
    private func applyActiveSupplementaryMasksIfNeeded(
        to window: OverlayWindow,
        displayID: DisplayID,
        preserving frozenMask: [OverlayWindow.MaskRegion]?
    ) -> Bool {
        guard let requests = supplementaryMaskRequestsForActiveSnapshot(
            intersecting: window.frame,
            excluding: nil,
            displayID: displayID
        ) else {
            return false
        }
        guard let supplementaryRegions = buildMaskRegions(from: requests, in: window, displayID: displayID) else {
            return false
        }
        let merged = mergedMaskRegions(frozenMask, supplementaryRegions)
        window.applyMask(regions: merged, animated: shouldAnimateMaskTransition(for: displayID))
        frozenMaskRegionsByDisplayID[displayID] = merged
        return true
    }

    /// Applies the supplied mask requests to the overlay window, accounting for blur tolerances.
    private func apply(
        maskRequests: [MaskRequest],
        to window: OverlayWindow,
        cachingDisplayID displayID: DisplayID? = nil,
        identity: WindowIdentity? = nil,
        animated: Bool
    ) -> Bool {
        guard let maskRegions = buildMaskRegions(from: maskRequests, in: window, displayID: displayID) else {
            return false
        }
        window.applyMask(regions: maskRegions, animated: animated)
        if let displayID {
            frozenMaskRegionsByDisplayID[displayID] = maskRegions
        }
        if let displayID, let identity {
            storeMaskRegions(maskRegions, for: displayID, identity: identity)
        }
        return true
    }

    private func shouldAnimateMaskTransition(for displayID: DisplayID) -> Bool {
        guard isMonitoringActive else { return false }
        if interactionBoostExpiration != nil { return false }
        if motionPredictor.hasRecentSignificantMovement(within: 0.18, now: CACurrentMediaTime()) { return false }
        if isDisplayLinkRunning { return false }
        if preferredPredictionFrameInterval > 0,
           activeDisplayID == displayID,
           requiresContinuousPrediction {
            return false
        }
        return true
    }

    private func shouldSimplifyMaskRequests(for displayID: DisplayID) -> Bool {
        if Date() < simplifiedMaskModeUntil {
            return true
        }
        if interactionBoostExpiration != nil, activeDisplayID == displayID {
            return true
        }
        if isDisplayLinkRunning, activeDisplayID == displayID {
            return true
        }
        return false
    }

    private func limitedPeripheralRequests(for displayID: DisplayID) -> [MaskRequest]? {
        guard let requests = peripheralMaskRequestsByDisplayID[displayID], !requests.isEmpty else {
            return nil
        }
        guard shouldSimplifyMaskRequests(for: displayID) else {
            return requests
        }
        if requests.count <= maximumPeripheralRequestsDuringSimplification {
            return requests
        }
        return Array(requests.prefix(maximumPeripheralRequestsDuringSimplification))
    }

    /// Translates mask requests into overlay-ready regions, or nil if nothing intersects.
    private func buildMaskRegions(
        from maskRequests: [MaskRequest],
        in window: OverlayWindow,
        displayID: DisplayID?
    ) -> [OverlayWindow.MaskRegion]? {
        guard let contentView = window.contentView else {
            return nil
        }
        guard !maskRequests.isEmpty else {
            return nil
        }

        pruneMaskRegionBuildCacheIfNeeded()

        let windowFrame = window.frame
        let contentBounds = contentView.bounds
        let backingScale = window.backingScaleFactor
        let fingerprint = maskRequestFingerprint(maskRequests, in: windowFrame)
        if let displayID,
           let cached = maskRegionBuildCacheByDisplayID[displayID],
           cached.fingerprint == fingerprint,
           abs(cached.backingScale - backingScale) <= 0.001,
           cached.windowFrame.isApproximatelyEqual(to: windowFrame, tolerance: 0.25),
           cached.contentBounds.isApproximatelyEqual(to: contentBounds, tolerance: 0.25) {
            return cached.regions
        }

        var maskRegions: [OverlayWindow.MaskRegion] = []
        maskRegions.reserveCapacity(maskRequests.count)

        let maxInflation: CGFloat = 1.1
        let displayArea = max(windowFrame.width * windowFrame.height, .ulpOfOne)

        for request in maskRequests {
            let expansion = maskExpansion(for: request.purpose)
            let baseIntersection = request.rect.intersection(windowFrame)
            guard !baseIntersection.isNull else { continue }

            // Skip obviously runaway rectangles relative to the display.
            if baseIntersection.width > windowFrame.width * maxInflation ||
                baseIntersection.height > windowFrame.height * maxInflation {
                continue
            }
            let area = baseIntersection.width * baseIntersection.height
            let areaRatio = area / displayArea
            if areaRatio < 0.0008 || areaRatio > 0.45 { // cap at 45% of the display
                continue
            }

            let expandedRect: NSRect
            if expansion != 0 {
                let expanded = baseIntersection.insetBy(dx: -expansion, dy: -expansion)
                expandedRect = expanded.intersection(windowFrame)
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
                    cornerRadius: adjustedCornerRadius(
                        for: request,
                        rect: finalRect,
                        expansion: expansion,
                        shrink: clampedShrink,
                        scale: backingScale
                    )
                )
            )
        }

        guard !maskRegions.isEmpty else { return nil }
        if let displayID {
            maskRegionBuildCacheByDisplayID[displayID] = MaskRegionBuildCacheEntry(
                fingerprint: fingerprint,
                windowFrame: windowFrame,
                contentBounds: contentBounds,
                backingScale: backingScale,
                regions: maskRegions,
                timestamp: Date()
            )
        }
        return maskRegions
    }

    private func maskRequestFingerprint(_ requests: [MaskRequest], in windowFrame: NSRect) -> Int {
        var hasher = Hasher()
        hasher.combine(requests.count)
        hasher.combine(quantized(windowFrame.origin.x, scale: 2))
        hasher.combine(quantized(windowFrame.origin.y, scale: 2))
        hasher.combine(quantized(windowFrame.width, scale: 2))
        hasher.combine(quantized(windowFrame.height, scale: 2))
        for request in requests {
            hasher.combine(quantized(request.rect.origin.x, scale: 4))
            hasher.combine(quantized(request.rect.origin.y, scale: 4))
            hasher.combine(quantized(request.rect.width, scale: 4))
            hasher.combine(quantized(request.rect.height, scale: 4))
            hasher.combine(quantized(request.cornerRadius, scale: 4))
            hasher.combine(maskPurposeFingerprint(request.purpose))
            hasher.combine(peripheralKindFingerprint(request.peripheralKind))
            hasher.combine(request.isSynthesizedPeripheral)
        }
        return hasher.finalize()
    }

    private func maskPurposeFingerprint(_ purpose: ActiveWindowSnapshot.MaskRegion.Purpose?) -> Int {
        guard let purpose else { return -1 }
        switch purpose {
        case .applicationWindow:
            return 0
        case .applicationMenu:
            return 1
        case .systemMenu:
            return 2
        }
    }

    private func peripheralKindFingerprint(_ kind: PeripheralInterfaceRegion.Kind?) -> Int {
        guard let kind else { return -1 }
        switch kind {
        case .dock(let edge, let isAutoHidden):
            return 100 + peripheralEdgeFingerprint(edge) * 10 + (isAutoHidden ? 1 : 0)
        case .stageManagerShelf(let edge, let cards):
            return 200 + peripheralEdgeFingerprint(edge) * 100 + min(cards.count, 99)
        }
    }

    private func peripheralEdgeFingerprint(_ edge: PeripheralEdge) -> Int {
        switch edge {
        case .leading:
            return 0
        case .trailing:
            return 1
        case .top:
            return 2
        case .bottom:
            return 3
        }
    }

    private func quantized(_ value: CGFloat, scale: CGFloat) -> Int {
        Int((value * scale).rounded())
    }

    private func pruneMaskRegionBuildCacheIfNeeded(referenceDate: Date = Date()) {
        guard !maskRegionBuildCacheByDisplayID.isEmpty else { return }
        let cutoff = referenceDate.addingTimeInterval(-maskRegionBuildCacheLifetime)
        maskRegionBuildCacheByDisplayID = maskRegionBuildCacheByDisplayID.filter { $0.value.timestamp >= cutoff }
    }

    /// Applies only peripheral carve-outs when no active window snapshot is available.
    private func applyPeripheralMasksIfNeeded(
        to window: OverlayWindow,
        displayID: DisplayID,
        preserving frozenMask: [OverlayWindow.MaskRegion]?
    ) -> Bool {
        guard let requests = limitedPeripheralRequests(for: displayID), !requests.isEmpty else {
            return false
        }
        guard let peripheralRegions = buildMaskRegions(from: requests, in: window, displayID: displayID) else {
            return false
        }
        let merged = mergedMaskRegions(frozenMask, peripheralRegions)
        window.applyMask(regions: merged, animated: shouldAnimateMaskTransition(for: displayID))
        frozenMaskRegionsByDisplayID[displayID] = merged
        return true
    }

    private func mergedMaskRegions(
        _ frozenMask: [OverlayWindow.MaskRegion]?,
        _ supplementalMask: [OverlayWindow.MaskRegion]
    ) -> [OverlayWindow.MaskRegion] {
        guard let frozenMask, !frozenMask.isEmpty else { return supplementalMask }
        guard !supplementalMask.isEmpty else { return frozenMask }
        var combined = frozenMask
        for region in supplementalMask where !combined.contains(region) {
            combined.append(region)
        }
        return combined
    }

    private func lastKnownMaskRegions(
        for displayID: DisplayID,
        cachedEntry: DisplaySnapshotCacheEntry?,
        ignoring ignoredIdentity: WindowIdentity? = nil
    ) -> [OverlayWindow.MaskRegion]? {
        if let frozen = frozenMaskRegionsByDisplayID[displayID], !frozen.isEmpty {
            return frozen
        }
        if let cachedEntry, !cachedEntry.maskRegions.isEmpty {
            return cachedEntry.maskRegions
        }
        guard let cache = cachedSnapshotsByDisplayID[displayID] else {
            return nil
        }
        if let entry = cache.mostRecentMaskEntry(excluding: ignoredIdentity) {
            return entry.maskRegions
        }
        return nil
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
        refreshBackgroundWindowCache()
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

    /// Keeps a recent cache of background window snapshots so window switches can be primed instantly.
    private func refreshBackgroundWindowCache(force: Bool = false) {
        guard isMonitoringActive else { return }
        let now = Date()
        if !force,
           now.timeIntervalSince(lastBackgroundSnapshotRefresh) < backgroundSnapshotRefreshInterval {
            pruneBackgroundSnapshotCache()
            return
        }
        lastBackgroundSnapshotRefresh = now
        let snapshots = resolveRecentWindowSnapshots(
            excluding: activeOverlayWindowNumbers(),
            limit: backgroundSnapshotLimit
        )
        guard !snapshots.isEmpty else {
            pruneBackgroundSnapshotCache()
            return
        }
        storeBackgroundSnapshots(snapshots, timestamp: now)
    }

    private func storeBackgroundSnapshots(_ snapshots: [ActiveWindowSnapshot], timestamp: Date) {
        var merged: [Int: BackgroundWindowSnapshot] = Dictionary(
            uniqueKeysWithValues: backgroundSnapshotEntries.map { ($0.windowNumber, $0) }
        )
        for snapshot in snapshots {
            guard let windowNumber = snapshot.windowNumber else { continue }
            merged[windowNumber] = BackgroundWindowSnapshot(
                windowNumber: windowNumber,
                ownerPID: snapshot.ownerPID,
                snapshot: snapshot,
                timestamp: timestamp
            )
        }
        backgroundSnapshotEntries = Array(merged.values)
        pruneBackgroundSnapshotCache()
    }

    private func pruneBackgroundSnapshotCache() {
        let cutoff = Date().addingTimeInterval(-backgroundSnapshotLifetime)
        backgroundSnapshotEntries.removeAll { $0.timestamp < cutoff }
        if backgroundSnapshotEntries.count > backgroundSnapshotLimit {
            backgroundSnapshotEntries.sort { $0.timestamp > $1.timestamp }
            backgroundSnapshotEntries = Array(backgroundSnapshotEntries.prefix(backgroundSnapshotLimit))
        }
    }

    private func cachedBackgroundSnapshot(forPID pid: pid_t) -> ActiveWindowSnapshot? {
        pruneBackgroundSnapshotCache()
        return backgroundSnapshotEntries
            .filter { $0.ownerPID == pid }
            .max(by: { $0.timestamp < $1.timestamp })?
            .snapshot
    }

    private func primeOverlayFromBackgroundCache(forPID pid: pid_t?) {
        guard let pid, isMonitoringActive else { return }
        guard let snapshot = cachedBackgroundSnapshot(forPID: pid) else { return }
        cacheActiveSnapshot(snapshot)
        applyOverlayMasksFromCache()
    }

    /// Timer callback that re-checks the focused window position.
    @objc private func handlePollingTimer(_ timer: Timer) {
        let didChange = refreshActiveWindowSnapshot()
        if didChange {
            exitQuiescentModeIfNeeded()
            enterInteractionBoost(minimumDuration: interactionBoostDuration)
        } else {
            evaluateQuiescentModeIfNeeded()
        }
        evaluateInteractionDeadline()
    }

    /// Determines how much a given mask should expand to cover drop-shadows and hover states.
    private func maskExpansion(for purpose: ActiveWindowSnapshot.MaskRegion.Purpose?) -> CGFloat {
        let dragActive = motionPredictor.hasRecentSignificantMovement(
            within: 0.18,
            now: CACurrentMediaTime()
        )
        switch purpose {
        case .systemMenu?:
            return dragActive ? 0.04 : 0.07
        case .applicationMenu?:
            return dragActive ? 0.035 : 0.06
        case .applicationWindow?:
            return dragActive ? 0.028 : 0.1
        case nil:
            return 0.1
        }
    }

    /// Slightly shrinks carved-out menus so their edges remain pixel-tight after rounding.
    private func maskShrink(for purpose: ActiveWindowSnapshot.MaskRegion.Purpose?, rect: NSRect) -> CGFloat {
        let dragActive = motionPredictor.hasRecentSignificantMovement(
            within: 0.18,
            now: CACurrentMediaTime()
        )
        switch purpose {
        case .systemMenu?, .applicationMenu?:
            let base = min(0.35, min(rect.width, rect.height) * 0.3)
            return dragActive ? base * 0.55 : base
        case .applicationWindow?, nil:
            return 0
        }
    }

    /// Adjusts the corner radius to match the expanded mask rect.
    private func adjustedCornerRadius(
        for request: MaskRequest,
        rect: NSRect,
        expansion: CGFloat,
        shrink: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        let baseRadius = max(0, request.cornerRadius)
        let expanded = expansion > 0 ? baseRadius + expansion : baseRadius
        let pixelEpsilon = scale > 0 ? (0.5 / scale) : 0
        var adjusted = expanded
        if shrink > 0 {
            adjusted = max(0, expanded - max(0, shrink - pixelEpsilon))
        }
        adjusted = max(0, adjusted + cornerRadiusBias(for: request.purpose))
        return refinedCornerRadius(for: rect, baseRadius: adjusted, purpose: request.purpose)
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

    /// Re-evaluates the requested corner radius so sharp-edged windows do not inherit oversized rounding.
    private func refinedCornerRadius(
        for rect: NSRect,
        baseRadius: CGFloat,
        purpose: ActiveWindowSnapshot.MaskRegion.Purpose?
    ) -> CGFloat {
        guard baseRadius > 0 else { return 0 }
        let minDimension = max(0, min(rect.width, rect.height))
        guard minDimension > 0 else { return 0 }
        var radius = min(baseRadius, minDimension / 2)
        guard purpose == .applicationWindow else {
            return radius
        }
        if minDimension <= 220 {
            radius *= 0.9
        } else if minDimension >= 720 {
            radius *= 1.05
        }
        let aspectRatio = max(rect.width, rect.height) / max(minDimension, CGFloat.ulpOfOne)
        if aspectRatio >= 2.6 {
            radius *= 0.82
        } else if aspectRatio >= 1.85 {
            radius *= 0.9
        }
        let normalizedRadius = radius / minDimension
        if normalizedRadius >= 0.42 {
            radius = min(minDimension * 0.42, radius * 0.95)
        }
        return radius
    }

    /// Creates and starts a pointer monitor so we can react to drag and resize interactions.
    private func configurePointerInteractionMonitoring() {
        if pointerInteractionMonitor == nil {
            pointerInteractionMonitor = PointerInteractionMonitor { [weak self] state, event in
                guard let self else { return }
                self.capturePointerDisplayHint(from: event)
                switch state {
                case .began, .dragged:
                    self.enterInteractionBoost(minimumDuration: self.interactionBoostDuration)
                    self.requestImmediateSnapshotRefreshIfNeeded()
                case .ended:
                    self.enterInteractionBoost(minimumDuration: self.interactionCooldownDuration)
                    self.requestImmediateSnapshotRefreshIfNeeded()
                }
            }
        }
        pointerInteractionMonitor?.start()
        startHighFrequencyPointerSamplingIfNeeded()
    }

    /// Tears down the pointer monitor when overlays are inactive.
    private func stopPointerInteractionMonitoring() {
        pointerInteractionMonitor?.stop()
        pointerInteractionMonitor = nil
        interactionBoostExpiration = nil
        stopDisplayLinkIfNeeded()
        stopHighFrequencyPointerSampling()
        lastPointerDragSample = nil
        pointerPredictionMinimumMovement = defaultPointerPredictionMinimumMovement
    }

    /// Starts a high-frequency event tap so drag updates stay in lockstep with the display cadence.
    private func startHighFrequencyPointerSamplingIfNeeded() {
        guard supportsPointerDrivenInteractionBoosts else { return }
        if highFrequencyPointerSampler == nil {
            highFrequencyPointerSampler = HighFrequencyPointerSampler { [weak self] location, isDragging, timestamp in
                self?.handleHighFrequencyPointerSample(location: location, isDragging: isDragging, timestamp: timestamp)
            }
        }
        highFrequencyPointerSampler?.start()
        applyPointerSamplingConfiguration(for: activeRefreshProfile())
    }

    /// Stops the high-frequency pointer sampler when overlays are inactive.
    private func stopHighFrequencyPointerSampling() {
        highFrequencyPointerSampler?.stop()
        highFrequencyPointerSampler = nil
        lastPointerDragSample = nil
    }

    /// Keeps the preferred display hint warm using the raw pointer stream.
    private func handleHighFrequencyPointerSample(location: NSPoint, isDragging: Bool, timestamp: CFTimeInterval) {
        guard isMonitoringActive else {
            lastPointerDragSample = nil
            return
        }
        updatePointerDisplayHint(for: location)
        guard isDragging else {
            lastPointerDragSample = nil
            return
        }
        enterInteractionBoost(minimumDuration: interactionBoostDuration)
        requestImmediateSnapshotRefreshIfNeeded()
        applyPointerDrivenPredictionSample(location: location, timestamp: timestamp)
    }

    /// Returns the lead time we should use when nudging predictions from pointer samples.
    private func pointerPredictionLeadTime() -> TimeInterval {
        if preferredPredictionFrameInterval > 0 {
            return preferredPredictionFrameInterval
        }
        if fastFrameSampleInterval.isFinite, fastFrameSampleInterval > 0 {
            return fastFrameSampleInterval
        }
        return 1.0 / 90.0
    }

    /// Uses the pointer delta to prime the motion predictor so masks stay ahead of the drag.
    private func applyPointerDrivenPredictionSample(location: NSPoint, timestamp: CFTimeInterval) {
        guard cachedActiveSnapshot != nil else {
            lastPointerDragSample = (location, timestamp)
            return
        }
        guard let lastSample = lastPointerDragSample else {
            lastPointerDragSample = (location, timestamp)
            return
        }
        let delta = CGVector(dx: location.x - lastSample.location.x, dy: location.y - lastSample.location.y)
        let distance = hypot(delta.dx, delta.dy)
        lastPointerDragSample = (location, timestamp)
        guard distance >= pointerPredictionMinimumMovement else { return }
        motionPredictor.applyPointerDelta(delta, timestamp: timestamp)
        let lead = pointerPredictionLeadTime()
        guard lead.isFinite, lead > 0 else { return }
        applyPredictedFrameIfPossible(leadTime: lead, force: true)
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
        updatePeripheralHoverState(for: initialLocation, forceRefresh: true)
    }

    /// Stops hover tracking and clears any stale peripheral carve-outs.
    private func stopPointerHoverMonitoring() {
        pointerHoverMonitor?.stop()
        pointerHoverMonitor = nil
        stopPeripheralAnimationDriver()
        resetDesktopRevealEvaluation()
        lastPointerLocation = nil
        if pointerDisplayIDHint != nil {
            pointerDisplayIDHint = nil
            updateDisplayLinkPreferredDisplay()
            updateDisplayPerformanceHints()
        }
        cachedPeripheralRegions = []
        lastPeripheralRegionRefresh = .distantPast
        if !peripheralMaskRequestsByDisplayID.isEmpty {
            peripheralMaskRequestsByDisplayID.removeAll()
            if isMonitoringActive {
                applyCachedOverlayMask()
            }
        }
    }

    /// Keeps an eye on workspace-level animations (Stage Manager, Cmd+Tab, Spaces) to boost tracking.
    private func startWorkspaceAnimationMonitoring() {
        guard workspaceAnimationObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let observedNames: [NSNotification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification
        ]
        workspaceAnimationObservers = observedNames.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor [weak self] in
                    self?.handleWorkspaceAnimationEvent(activatedApplication: activatedApplication)
                }
            }
        }
    }

    /// Stops listening for workspace animation hints.
    private func stopWorkspaceAnimationMonitoring() {
        guard !workspaceAnimationObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceAnimationObservers.forEach { center.removeObserver($0) }
        workspaceAnimationObservers.removeAll()
    }

    /// Keeps overlay caches warm across sleep/wake so the last window can be restored instantly.
    private func startPowerMonitoring() {
        guard powerObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        powerObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleWillSleep()
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleDidWake()
                }
            }
        ]
    }

    /// Tears down sleep/wake observers.
    private func stopPowerMonitoring() {
        guard !powerObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.forEach { center.removeObserver($0) }
        powerObservers.removeAll()
    }

    private func handleWillSleep() {
        sleepPreservationState = SleepPreservationState(
            activeSnapshot: cachedActiveSnapshot,
            cachedSnapshots: cachedSnapshotsByDisplayID,
            activeDisplayID: activeDisplayID,
            timestamp: Date()
        )
    }

    private func handleDidWake() {
        restorePreservedSnapshotStateIfNeeded()
        requestImmediateSnapshotRefreshIfNeeded()
    }

    /// Temporarily enters the high-frequency tracking mode when macOS animates the frontmost app.
    private func handleWorkspaceAnimationEvent(activatedApplication: NSRunningApplication? = nil) {
        guard isMonitoringActive else { return }
        enterInteractionBoost(minimumDuration: animationBoostDuration)
        requestImmediateSnapshotRefreshIfNeeded()
        prewarmPredictionsForImpendingAnimation()
        refreshBackgroundWindowCache(force: true)
        if let pid = activatedApplication?.processIdentifier {
            primeOverlayFromBackgroundCache(forPID: pid)
        }
    }

    /// Determines the most appropriate lead time when pre-warming predictions for macOS animations.
    private func desiredAnimationLeadTime() -> TimeInterval {
        let candidate: TimeInterval
        if preferredPredictionFrameInterval > 0 {
            candidate = preferredPredictionFrameInterval
        } else if lastDisplayLinkRefreshInterval > 0 {
            candidate = lastDisplayLinkRefreshInterval
        } else {
            candidate = 1.0 / 60.0
        }
        return resolvedPredictionLeadInterval(for: candidate, profile: activeRefreshProfile())
    }

    /// Ensures predictions are refreshed before macOS animates windows across displays or spaces.
    private func prewarmPredictionsForImpendingAnimation() {
        guard cachedActiveSnapshot != nil else { return }
        let lead = desiredAnimationLeadTime()
        guard lead > 0 else { return }
        applyPredictedFrameIfPossible(leadTime: lead, force: true)
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

    /// Forces a snapshot refresh outside the normal polling cadence so masks can collapse faster.
    private func requestImmediateSnapshotRefreshIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastImmediateSnapshotRefresh) >= resolvedImmediateSnapshotCooldown else {
            return
        }
        lastImmediateSnapshotRefresh = now
        _ = refreshActiveWindowSnapshot()
    }

    /// Reads the current mouse location and updates the display-link preference.
    private func capturePointerDisplayHintFromSystem() {
        updatePointerDisplayHint(for: NSEvent.mouseLocation)
    }

    /// Updates the pointer hint using the supplied NSEvent's location.
    private func capturePointerDisplayHint(from event: NSEvent) {
        updatePointerDisplayHint(for: event.locationInWindow)
    }

    /// Updates the display-link preference using the supplied pointer location.
    private func updatePointerDisplayHint(for location: NSPoint) {
        lastPointerLocation = location
        let resolvedID = pointerDisplayIdentifier(for: location)
        guard resolvedID != pointerDisplayIDHint else { return }
        pointerDisplayIDHint = resolvedID
        updateDisplayLinkPreferredDisplay()
        updateDisplayPerformanceHints()
    }

    /// Maps a global pointer coordinate to a display identifier if possible.
    private func pointerDisplayIdentifier(for location: NSPoint) -> DisplayID? {
        for screen in NSScreen.screens where screen.frame.contains(location) {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            return DisplayID(truncating: number)
        }
        return nil
    }

    /// Recomputes hover-dependent carve-outs for Dock/Stage Manager surfaces.
    private func updatePeripheralHoverState(for location: NSPoint, forceRefresh: Bool = false) {
        guard isMonitoringActive else { return }
        lastPointerLocation = location
        updatePointerDisplayHint(for: location)
        if forceRefresh {
            refreshPeripheralRegionsIfNeeded(force: true)
        } else {
            refreshPeripheralRegionsIfNeeded()
        }
        let revealAll = shouldForcePeripheralReveal()
        var updatedRequests = buildPeripheralMaskRequests(for: location, forceRevealAll: revealAll)
        updatedRequests = sustainDockMaskRequestsIfNeeded(currentRequests: updatedRequests, pointerLocation: location)
        if peripheralRequestsAreEqual(updatedRequests, peripheralMaskRequestsByDisplayID) {
            return
        }
        peripheralMaskRequestsByDisplayID = updatedRequests
        applyCachedOverlayMask()
        updatePeripheralAnimationDriver()
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
            if region.kind.isAutoHiddenDock && region.isSynthesized {
                let touchesEdge = region.kind.pointerTouchesDockEdge(
                    for: location,
                    frame: region.frame,
                    tolerance: autoHiddenDockEdgeContactTolerance
                )
                if !touchesEdge {
                    continue
                }
            }
            let bypassHoverRequirement = forceRevealAll && !region.kind.requiresHoverForForcedReveal
            if !bypassHoverRequirement && !region.hoverRect.contains(location) {
                let shouldRevealDock = region.kind.isAutoHiddenDock && !region.isSynthesized
                if !shouldRevealDock {
                    continue
                }
            }
            guard overlayWindowsByDisplayID[region.displayID] != nil else { continue }
            let sanitizedKind = region.kind.sanitizedForMaskRequests
            if case .stageManagerShelf(let edge, let cards) = region.kind {
                let stageRequests = stageManagerMaskRequests(
                    for: region,
                    sanitizedKind: sanitizedKind,
                    edge: edge,
                    cards: cards
                )
                guard !stageRequests.isEmpty else { continue }
                requests[region.displayID, default: []].append(contentsOf: stageRequests)
                continue
            }
            let request = MaskRequest(
                rect: region.frame,
                cornerRadius: region.cornerRadius,
                purpose: .systemMenu,
                peripheralKind: sanitizedKind,
                isSynthesizedPeripheral: region.isSynthesized
            )
            requests[region.displayID, default: []].append(request)
        }
        return requests
    }

    /// Keeps existing Dock carve-outs alive while the pointer is still within their masked area.
    private func sustainDockMaskRequestsIfNeeded(
        currentRequests: [DisplayID: [MaskRequest]],
        pointerLocation: NSPoint
    ) -> [DisplayID: [MaskRequest]] {
        guard !peripheralMaskRequestsByDisplayID.isEmpty else { return currentRequests }
        var mergedRequests = currentRequests
        for (displayID, previousRequests) in peripheralMaskRequestsByDisplayID {
            let sustained = previousRequests.filter { request in
                request.describesDock && request.rect.contains(pointerLocation)
            }
            guard !sustained.isEmpty else { continue }
            var updatedDisplayRequests = mergedRequests[displayID, default: []]
            for request in sustained {
                if updatedDisplayRequests.contains(where: { $0 == request }) {
                    continue
                }
                updatedDisplayRequests.append(request)
            }
            mergedRequests[displayID] = updatedDisplayRequests
        }
        return mergedRequests
    }

    private func stageManagerMaskRequests(
        for region: PeripheralInterfaceRegion,
        sanitizedKind: PeripheralInterfaceRegion.Kind,
        edge: PeripheralEdge,
        cards: [PeripheralInterfaceRegion.StageManagerCard]
    ) -> [MaskRequest] {
        guard !cards.isEmpty else {
            return [
                MaskRequest(
                    rect: region.frame,
                    cornerRadius: region.cornerRadius,
                    purpose: .systemMenu,
                    peripheralKind: sanitizedKind,
                    isSynthesizedPeripheral: region.isSynthesized
                )
            ]
        }
        var maskRequests: [MaskRequest] = []
        for card in cards {
            let cardCornerRadius = stageManagerCardCornerRadius(for: card.frame)
            let previewRects = trapezoidalCardRects(for: card.frame, shelfEdge: edge)
            for rect in previewRects {
                maskRequests.append(
                    MaskRequest(
                        rect: rect,
                        cornerRadius: cardCornerRadius,
                        purpose: .systemMenu,
                        peripheralKind: sanitizedKind,
                        isSynthesizedPeripheral: region.isSynthesized
                    )
                )
            }
            if let iconRect = stageManagerIconRect(for: card.frame, shelfEdge: edge) {
                let iconCornerRadius = min(iconRect.width, iconRect.height) / 2
                maskRequests.append(
                    MaskRequest(
                        rect: iconRect,
                        cornerRadius: iconCornerRadius,
                        purpose: .systemMenu,
                        peripheralKind: sanitizedKind,
                        isSynthesizedPeripheral: region.isSynthesized
                    )
                )
            }
        }
        return maskRequests
    }

    private func trapezoidalCardRects(for cardFrame: NSRect, shelfEdge edge: PeripheralEdge) -> [NSRect] {
        let proposedTopHeight = max(cardFrame.height * 0.42, 48)
        let clampedTopHeight = min(proposedTopHeight, cardFrame.height * 0.8)
        let bottomHeight = max(cardFrame.height - clampedTopHeight, 36)
        let topHeight = max(cardFrame.height - bottomHeight, 24)
        let skew = max(cardFrame.width * 0.08, 10)
        let bottomRect = NSRect(
            x: cardFrame.minX,
            y: cardFrame.minY,
            width: cardFrame.width,
            height: bottomHeight
        )
        var topRect = NSRect(
            x: cardFrame.minX,
            y: cardFrame.maxY - topHeight,
            width: cardFrame.width,
            height: topHeight
        )
        switch edge {
        case .leading:
            topRect.origin.x = min(cardFrame.maxX, topRect.origin.x + skew)
            topRect.size.width = max(cardFrame.width - skew, cardFrame.width * 0.35)
        case .trailing:
            topRect.size.width = max(cardFrame.width - skew, cardFrame.width * 0.35)
        case .top, .bottom:
            break
        }
        return [bottomRect, topRect]
    }

    private func stageManagerCardCornerRadius(for frame: NSRect) -> CGFloat {
        let minDimension = max(1, min(frame.width, frame.height))
        return min(minDimension * 0.18, 34)
    }

    private func stageManagerIconRect(for frame: NSRect, shelfEdge edge: PeripheralEdge) -> NSRect? {
        let iconSize = min(frame.width, frame.height) * 0.28
        guard iconSize >= 12 else { return nil }
        let inset = iconSize * 0.25
        let y = frame.minY + inset
        let x: CGFloat
        switch edge {
        case .leading:
            x = frame.minX + inset
        case .trailing:
            x = frame.maxX - iconSize - inset
        case .top, .bottom:
            x = frame.minX + inset
        }
        return NSRect(x: x, y: y, width: iconSize, height: iconSize)
    }

    /// Enables or disables the animation driver depending on active auto-hidden Dock carve-outs.
    private func updatePeripheralAnimationDriver() {
        if hasActiveAutoHiddenDockMask() {
            startPeripheralAnimationDriver()
        } else {
            stopPeripheralAnimationDriver()
        }
    }

    /// Returns whether any active mask request describes a dock that macOS auto-hides.
    private func hasActiveAutoHiddenDockMask() -> Bool {
        for requests in peripheralMaskRequestsByDisplayID.values {
            if requests.contains(where: { $0.requiresAutoHiddenDockAnimation }) {
                return true
            }
        }
        return false
    }

    /// Starts a short-lived timer so Dock carve-outs follow macOS' autohide animation.
    private func startPeripheralAnimationDriver() {
        guard peripheralAnimationTimer == nil else { return }
        let interval = max(resolvedPeripheralAnimationInterval, 1.0 / 360.0)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePeripheralAnimationTick()
            }
        }
        peripheralAnimationTimer = timer
        activePeripheralAnimationInterval = interval
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Stops the animation driver when it is no longer needed.
    private func stopPeripheralAnimationDriver() {
        guard let timer = peripheralAnimationTimer else { return }
        timer.invalidate()
        peripheralAnimationTimer = nil
        activePeripheralAnimationInterval = nil
    }

    /// Keeps sampling Dock regions while the system animates them on or off screen.
    private func handlePeripheralAnimationTick() {
        guard isMonitoringActive else {
            stopPeripheralAnimationDriver()
            return
        }
        guard hasActiveAutoHiddenDockMask() else {
            stopPeripheralAnimationDriver()
            return
        }
        let location = lastPointerLocation ?? NSEvent.mouseLocation
        updatePeripheralHoverState(for: location, forceRefresh: true)
    }

    /// Determines whether Dock/Stage Manager should be revealed regardless of pointer position.
    private func shouldForcePeripheralReveal() -> Bool {
        guard isDesktopPeripheralRevealEnabled else { return false }
        if cachedActiveSnapshot == nil {
            return true
        }
        return evaluateDesktopRevealDecision()
    }

    /// Returns the cached desktop reveal decision, recomputing if the frontmost app changed or cache expired.
    private func evaluateDesktopRevealDecision() -> Bool {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let now = Date()
        let needsRefresh = frontmostPID != cachedDesktopRevealProcessID ||
            now.timeIntervalSince(lastDesktopRevealEvaluation) >= desktopRevealEvaluationInterval
        if needsRefresh {
            cachedDesktopRevealDecision = resolveDesktopRevealDecision(currentPID: frontmostPID)
            cachedDesktopRevealProcessID = frontmostPID
            lastDesktopRevealEvaluation = now
        }
        return cachedDesktopRevealDecision
    }

    /// Determines whether the frontmost application currently has any visible, non-minimized windows.
    private func resolveDesktopRevealDecision(currentPID: pid_t?) -> Bool {
        guard let pid = currentPID else { return false }
        if pid == ProcessInfo.processInfo.processIdentifier {
            return false
        }
        guard isAccessibilityAccessGranted() else { return false }

        let windowInfos = axWindowInfos(for: pid, limit: 80)
        guard !windowInfos.isEmpty else {
            return true
        }

        let hasVisibleWindow = windowInfos.contains { info in
            guard !info.isMinimized else { return false }
            let minDimension: CGFloat = 32
            return info.frame.width > minDimension && info.frame.height > minDimension
        }
        return !hasVisibleWindow
    }

    /// Clears cached desktop reveal state so the next evaluation runs immediately.
    private func resetDesktopRevealEvaluation() {
        cachedDesktopRevealDecision = false
        cachedDesktopRevealProcessID = nil
        lastDesktopRevealEvaluation = .distantPast
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
        timer.tolerance = pollingTimerTolerance(for: interval)
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

    /// Returns the tolerance to apply to the polling timer so macOS can coalesce wake-ups.
    private func pollingTimerTolerance(for interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite, interval > 0 else { return minimumPollingTimerTolerance }
        let scaledTolerance = interval * pollingTimerToleranceFraction
        return min(max(scaledTolerance, minimumPollingTimerTolerance), maximumPollingTimerTolerance)
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
        exitQuiescentModeIfNeeded()
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
            if !isInQuiescentMode, currentPollingInterval != currentPollingCadence.idleInterval {
                updatePollingIntervalIfNeeded(currentPollingCadence.idleInterval)
            }
            return
        }

        if Date() >= deadline {
            interactionBoostExpiration = nil
            if !isInQuiescentMode {
                updatePollingIntervalIfNeeded(currentPollingCadence.idleInterval)
            }
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
        updateFastFrameSamplingInterval(for: normalizedInterval)
        let profile = activeRefreshProfile()
        let predictionInterval = resolvedPredictionLeadInterval(for: normalizedInterval, profile: profile)
        applyPredictedFrameIfPossible(leadTime: predictionInterval)
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

    /// Determines how far ahead predictions should be biased for the supplied interval/profile.
    private func resolvedPredictionLeadInterval(for interval: TimeInterval, profile: DisplayRefreshProfile?) -> TimeInterval {
        let safeInterval = interval.isFinite && interval > 0 ? interval : 1.0 / 60.0
        guard let profile else {
            return min(max(safeInterval, 1.0 / 120.0), maximumPredictionLeadTime)
        }
        var lead = max(safeInterval, profile.preferredFrameInterval)
        if profile.usesVariableRefreshRate && profile.isBuiltIn {
            lead = max(lead, profile.preferredFrameInterval * 1.35)
        } else if profile.preferredFramesPerSecond >= 165 {
            lead = max(lead, safeInterval * 1.45)
        } else if profile.preferredFramesPerSecond >= 144 {
            lead = max(lead, safeInterval * 1.3)
        } else if profile.preferredFramesPerSecond >= 120 {
            lead = max(lead, safeInterval * 1.15)
        }
        return min(max(lead, 1.0 / 150.0), maximumPredictionLeadTime)
    }

    /// Adjusts the fast-frame sampling interval to follow the currently active display cadence.
    private func updateFastFrameSamplingInterval(for displayInterval: TimeInterval) {
        guard displayInterval.isFinite, displayInterval > 0 else { return }
        let multiplier: Double
        if supportsHighRefreshCompositing, displayInterval < (1.0 / 120.0) {
            multiplier = 0.7
        } else if displayInterval < (1.0 / 90.0) {
            multiplier = 0.85
        } else {
            multiplier = 1.05
        }
        let candidate = displayInterval * multiplier
        let clamped = min(
            max(candidate, fastFrameSamplingBounds.minimum),
            fastFrameSamplingBounds.maximum
        )
        fastFrameSampleInterval = clamped
    }

    /// Boosts the lead time for higher-refresh displays so overlays stay ahead of rapid panels.
    private func predictiveLeadMultiplier(for interval: TimeInterval, profile: DisplayRefreshProfile?) -> Double {
        guard interval > 0 else { return 1 }
        let framesPerSecond = profile?.preferredFramesPerSecond ?? (1.0 / interval)
        if framesPerSecond >= 165 {
            return 2.0
        }
        if framesPerSecond >= 144 {
            return 1.85
        }
        if framesPerSecond >= 120 {
            return 1.65
        }
        if framesPerSecond >= 90 {
            return 1.35
        }
        if framesPerSecond >= 75 {
            return 1.15
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
    private func applyPredictedFrameIfPossible(leadTime: TimeInterval, force: Bool = false) {
        guard leadTime > 0 else { return }
        guard let snapshot = cachedActiveSnapshot else { return }
        guard let displayID = activeDisplayID else { return }
        guard overlayWindowsByDisplayID[displayID] != nil else { return }
        let profile = displayRefreshProfiles[displayID]
        let now = CACurrentMediaTime()
        let bypassIdleSuppression = force || requiresContinuousPrediction || (profile?.demandsContinuousPrediction == true)
        if !bypassIdleSuppression,
           interactionBoostExpiration == nil,
           !motionPredictor.hasRecentSignificantMovement(within: predictionIdleSuppressionInterval, now: now) {
            if predictedSnapshotsByDisplayID.removeValue(forKey: displayID) != nil {
                applyOverlayMasksFromCache()
            }
            return
        }
        let leadMultiplier = predictiveLeadMultiplier(for: leadTime, profile: profile)
        var boostedLead = leadTime * (leadMultiplier + predictiveLeadCompensationFraction)
        if shouldBiasPredictionsOneFrameAhead {
            let oneFrameLead = preferredPredictionFrameInterval > 0 ? preferredPredictionFrameInterval : leadTime
            boostedLead += min(oneFrameLead, maximumPredictionLeadTime / 2)
        } else if profile?.wantsFrameAheadPrediction == true {
            boostedLead += leadTime
        }
        if (isSecondGenerationAppleSilicon || isThirdGenerationAppleSilicon),
           let profile,
           profile.preferredFramesPerSecond >= 120 {
            let fraction: Double = isThirdGenerationAppleSilicon ? 0.75 : 0.5
            boostedLead += min(leadTime * fraction, maximumPredictionLeadTime / 2)
        }
        boostedLead = min(boostedLead, maximumPredictionLeadTime)
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
        let areaRatio = (max(predictedFrame.width * predictedFrame.height, .ulpOfOne)) /
        max(snapshot.frame.width * snapshot.frame.height, .ulpOfOne)
        let sizeRatio = max(predictedFrame.width / max(snapshot.frame.width, 1),
                            predictedFrame.height / max(snapshot.frame.height, 1))
        let sizeOK = sizeRatio >= 0.55 && sizeRatio <= 1.2
        if !sizeOK || areaRatio < 0.55 || areaRatio > 1.4 {
            // Discard runaway predictions that would balloon the mask.
            if predictedSnapshotsByDisplayID.removeValue(forKey: displayID) != nil {
                applyOverlayMasksFromCache()
            }
            return
        }
        if centerShift < minimumPredictionDelta && sizeShift < minimumPredictionDelta {
            if predictedSnapshotsByDisplayID.removeValue(forKey: displayID) != nil {
                applyOverlayMasksFromCache()
            }
            return
        }

        let predictedSnapshot = ActiveWindowSnapshot(
            frame: predictedFrame,
            cornerRadius: snapshot.cornerRadius,
            supplementaryMasks: translatedMasks(
                snapshot.supplementaryMasks,
                dx: predictedFrame.origin.x - snapshot.frame.origin.x,
                dy: predictedFrame.origin.y - snapshot.frame.origin.y
            )
        )
        if predictedSnapshotsByDisplayID[displayID] == predictedSnapshot {
            return
        }
        predictedSnapshotsByDisplayID[displayID] = predictedSnapshot
        applyOverlayMasksFromCache()
    }

    /// Biases the mask forward by roughly one frame on displays that demand tighter tracking.
    private func primePredictionForCurrentFrameIfNeeded() {
        guard shouldBiasPredictionsOneFrameAhead else { return }
        let lead: TimeInterval
        if preferredPredictionFrameInterval > 0 {
            lead = preferredPredictionFrameInterval
        } else if fastFrameSampleInterval.isFinite, fastFrameSampleInterval > 0 {
            lead = fastFrameSampleInterval
        } else {
            lead = 1.0 / 90.0
        }
        applyPredictedFrameIfPossible(leadTime: lead, force: true)
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
            applyOverlayMasksFromCache()
            return .needsFallback
        }

        let tolerance: CGFloat = 0.35
        if cachedSnapshot.frame.isApproximatelyEqual(to: cgFrame, tolerance: tolerance) {
            motionPredictor.record(frame: cgFrame)
            applyOverlayMasksFromCache()
            return .noChange
        }

        let dx = cgFrame.origin.x - cachedSnapshot.frame.origin.x
        let dy = cgFrame.origin.y - cachedSnapshot.frame.origin.y
        cachedSnapshot = ActiveWindowSnapshot(
            frame: cgFrame,
            cornerRadius: cachedSnapshot.cornerRadius,
            supplementaryMasks: translatedMasks(
                cachedSnapshot.supplementaryMasks,
                dx: dx,
                dy: dy
            )
        )
        cacheActiveSnapshot(cachedSnapshot)
        rebindActiveSnapshotDisplays(for: cachedSnapshot)
        applyOverlayMasksFromCache()
        return .updated
    }
}

#if DEBUG
extension OverlayController {
    func testingFrozenMaskRegions(for displayID: DisplayID) -> [OverlayWindow.MaskRegion]? {
        frozenMaskRegionsByDisplayID[displayID]
    }

    func testingMergedMaskRegions(
        frozen: [OverlayWindow.MaskRegion]?,
        supplemental: [OverlayWindow.MaskRegion]
    ) -> [OverlayWindow.MaskRegion] {
        mergedMaskRegions(frozen, supplemental)
    }

    func testingLastKnownMaskRegions(
        for displayID: DisplayID,
        frozenMask: [OverlayWindow.MaskRegion]?,
        cachedMask: [OverlayWindow.MaskRegion]?,
        preferredCacheMask: [OverlayWindow.MaskRegion]? = nil
    ) -> [OverlayWindow.MaskRegion]? {
        if let frozenMask {
            frozenMaskRegionsByDisplayID[displayID] = frozenMask
        } else {
            frozenMaskRegionsByDisplayID.removeValue(forKey: displayID)
        }

        cachedSnapshotsByDisplayID.removeValue(forKey: displayID)

        var cachedEntry: DisplaySnapshotCacheEntry?
        var cachedIdentity: WindowIdentity?
        let now = Date()

        if let cachedMask {
            let snapshot = ActiveWindowSnapshot(
                frame: NSRect(x: 0, y: 0, width: 80, height: 80),
                cornerRadius: 6,
                supplementaryMasks: []
            )
            let identity = WindowIdentity(snapshot: snapshot)
            storeSnapshot(snapshot, identity: identity, for: displayID, timestamp: now)
            storeMaskRegions(cachedMask, for: displayID, identity: identity, timestamp: now)
            cachedEntry = cachedSnapshotsByDisplayID[displayID]?.entry(for: identity)
            cachedIdentity = identity
        }

        if let preferredCacheMask {
            let snapshot = ActiveWindowSnapshot(
                frame: NSRect(x: 20, y: 20, width: 60, height: 60),
                cornerRadius: 4,
                supplementaryMasks: []
            )
            let identity = WindowIdentity(snapshot: snapshot)
            let timestamp = now.addingTimeInterval(-1)
            storeSnapshot(snapshot, identity: identity, for: displayID, timestamp: timestamp)
            storeMaskRegions(preferredCacheMask, for: displayID, identity: identity, timestamp: timestamp)
        }

        if cachedMask == nil, preferredCacheMask == nil {
            cachedSnapshotsByDisplayID.removeValue(forKey: displayID)
        }

        return lastKnownMaskRegions(for: displayID, cachedEntry: cachedEntry, ignoring: cachedIdentity)
    }
}
#endif

/// Translates mask regions by a delta so cached geometry can be re-used during prediction/drag.
private func translatedMasks(
    _ masks: [ActiveWindowSnapshot.MaskRegion],
    dx: CGFloat,
    dy: CGFloat
) -> [ActiveWindowSnapshot.MaskRegion] {
    guard (dx != 0 || dy != 0), !masks.isEmpty else { return masks }
    return masks.map { region in
        var frame = region.frame
        frame.origin.x += dx
        frame.origin.y += dy
        return ActiveWindowSnapshot.MaskRegion(
            frame: frame,
            cornerRadius: region.cornerRadius,
            purpose: region.purpose
        )
    }
}

extension OverlayController: OverlayServiceDelegate {
    /// Receives overlay updates from the service and replaces the managed window set.
    func overlayService(_ service: OverlayService, didUpdateOverlays updatedOverlayWindows: [DisplayID: OverlayWindow]) {
        refreshOverlayWindows(updatedOverlayWindows)
    }
}

private extension PeripheralInterfaceRegion.Kind {
    var isAutoHiddenDock: Bool {
        if case .dock(_, let isAutoHidden) = self {
            return isAutoHidden
        }
        return false
    }

    /// Determines whether forced desktop reveals should still wait for pointer hover.
    var requiresHoverForForcedReveal: Bool {
        switch self {
        case .dock, .stageManagerShelf:
            return true
        }
    }

    var dockEdge: PeripheralEdge? {
        if case .dock(let edge, _) = self {
            return edge
        }
        return nil
    }

    func pointerTouchesDockEdge(for location: NSPoint, frame: NSRect, tolerance: CGFloat) -> Bool {
        guard let edge = dockEdge else { return false }
        switch edge {
        case .bottom:
            return location.y <= frame.minY + tolerance
        case .top:
            return location.y >= frame.maxY - tolerance
        case .leading:
            return location.x <= frame.minX + tolerance
        case .trailing:
            return location.x >= frame.maxX - tolerance
        }
    }

    var sanitizedForMaskRequests: PeripheralInterfaceRegion.Kind {
        switch self {
        case .stageManagerShelf(let edge, _):
            return .stageManagerShelf(edge: edge, cards: [])
        case .dock:
            return self
        }
    }
}
