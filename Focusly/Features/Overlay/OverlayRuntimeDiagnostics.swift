import Foundation
import os.log

/// Lightweight diagnostics for scheduler and mask pipeline behavior.
@MainActor
final class OverlayRuntimeDiagnostics {
    enum EventSource: String, CaseIterable {
        case activeAppChange
        case windowMoveResize
        case screenChange
        case spaceChange
        case workspaceAnimation
        case manualRefresh
    }

    enum Diagnosis: String {
        case schedulerStarvation = "A"
        case slowMaskPipeline = "B"
        case fallbackModeCadence = "C"
    }

    struct HUDSnapshot {
        let eventsPerSecond: Double
        let updatesPerSecond: Double
        let averageUpdateDuration: TimeInterval
        let p95UpdateDuration: TimeInterval
        let averageEventToUpdateDelay: TimeInterval
        let averageCoalescedEventsPerUpdate: Double
        let averageMaskBuildDuration: TimeInterval
        let p95MaskBuildDuration: TimeInterval
        let averageLayerApplyDuration: TimeInterval
        let p95LayerApplyDuration: TimeInterval
        let mode: String
        let lastFallbackReason: String
        let diagnosis: Diagnosis?
    }

    private struct TimedValue {
        let timestamp: Date
        let value: Double
    }

    private let logger = Logger(subsystem: "com.focusly.app", category: "OverlayDebugHUD")
    private let consoleSummaryEnabled: Bool
    private var nextSummaryDeadline = Date.distantPast
    private var eventTimestamps: [Date] = []
    private var updateStartTimestamps: [Date] = []
    private var updateDurations: [TimedValue] = []
    private var eventToUpdateDelays: [TimedValue] = []
    private var coalescedEventsPerUpdate: [TimedValue] = []
    private var maskBuildDurations: [TimedValue] = []
    private var layerApplyDurations: [TimedValue] = []

    private(set) var currentMode = "fast"
    private(set) var lastFallbackReason = "none"
    private(set) var lastEventTimestampBySource: [EventSource: Date] = [:]
    private(set) var lastUpdateRequest: (timestamp: Date, reason: String)?
    private(set) var lastUpdateStartedAt: Date?
    private(set) var lastUpdateFinishedAt: Date?

    init() {
        let defaultsEnabled = UserDefaults.standard.bool(forKey: "Focusly.OverlayDebugHUDConsoleEnabled")
        let envEnabled = ProcessInfo.processInfo.environment["FOCUSLY_OVERLAY_DEBUG_HUD"] == "1"
        #if DEBUG
        consoleSummaryEnabled = defaultsEnabled || envEnabled || true
        #else
        consoleSummaryEnabled = defaultsEnabled || envEnabled
        #endif
    }

    /// Records incoming trigger events and tracks the latest source timestamp.
    func recordEventReceived(reason: UpdateCoordinator.Reason, at timestamp: Date = Date()) {
        eventTimestamps.append(timestamp)
        lastUpdateRequest = (timestamp, reason.rawValue)
        lastEventTimestampBySource[eventSource(for: reason)] = timestamp
        trimSamples(reference: timestamp)
    }

    /// Records the start of a coalesced update and captures event-to-update latency.
    func recordUpdateStarted(_ work: UpdateCoordinator.Work, at timestamp: Date = Date()) {
        updateStartTimestamps.append(timestamp)
        lastUpdateStartedAt = timestamp
        coalescedEventsPerUpdate.append(TimedValue(timestamp: timestamp, value: Double(max(work.coalescedEventCount, 1))))
        let delay = max(0, timestamp.timeIntervalSince(work.firstEventAt))
        eventToUpdateDelays.append(TimedValue(timestamp: timestamp, value: delay))
        trimSamples(reference: timestamp)
    }

    /// Records update completion duration for rolling averages and percentiles.
    func recordUpdateFinished(duration: TimeInterval, at timestamp: Date = Date()) {
        updateDurations.append(TimedValue(timestamp: timestamp, value: max(0, duration)))
        lastUpdateFinishedAt = timestamp
        trimSamples(reference: timestamp)
    }

    /// Records mask-build and layer-apply timings from the rendering pipeline.
    func recordMaskTimings(buildDuration: TimeInterval, layerApplyDuration: TimeInterval, at timestamp: Date = Date()) {
        maskBuildDurations.append(TimedValue(timestamp: timestamp, value: max(0, buildDuration)))
        layerApplyDurations.append(TimedValue(timestamp: timestamp, value: max(0, layerApplyDuration)))
        trimSamples(reference: timestamp)
    }

    /// Updates fallback mode metadata exposed in the debug HUD snapshot.
    func updateFallbackState(mode: String, reason: String) {
        currentMode = mode
        lastFallbackReason = reason
    }

    /// Produces a one-second rolling diagnostic snapshot for UI and logging.
    func hudSnapshot(reference: Date = Date()) -> HUDSnapshot {
        trimSamples(reference: reference)
        let eventsPerSecond = Double(eventTimestamps.count)
        let updatesPerSecond = Double(updateStartTimestamps.count)
        let averageUpdateDuration = average(of: updateDurations)
        let p95UpdateDuration = percentile(of: updateDurations, percentile: 0.95)
        let averageDelay = average(of: eventToUpdateDelays)
        let averageCoalesced = average(of: coalescedEventsPerUpdate)
        let averageBuild = average(of: maskBuildDurations)
        let p95Build = percentile(of: maskBuildDurations, percentile: 0.95)
        let averageLayerApply = average(of: layerApplyDurations)
        let p95LayerApply = percentile(of: layerApplyDurations, percentile: 0.95)
        return HUDSnapshot(
            eventsPerSecond: eventsPerSecond,
            updatesPerSecond: updatesPerSecond,
            averageUpdateDuration: averageUpdateDuration,
            p95UpdateDuration: p95UpdateDuration,
            averageEventToUpdateDelay: averageDelay,
            averageCoalescedEventsPerUpdate: averageCoalesced,
            averageMaskBuildDuration: averageBuild,
            p95MaskBuildDuration: p95Build,
            averageLayerApplyDuration: averageLayerApply,
            p95LayerApplyDuration: p95LayerApply,
            mode: currentMode,
            lastFallbackReason: lastFallbackReason,
            diagnosis: diagnosis(from: eventsPerSecond, updatesPerSecond: updatesPerSecond, averageUpdateDuration: averageUpdateDuration)
        )
    }

    /// Emits a throttled console summary when HUD logging is enabled.
    func maybeEmitSummary(reference: Date = Date()) {
        guard consoleSummaryEnabled else { return }
        if nextSummaryDeadline == .distantPast {
            nextSummaryDeadline = reference.addingTimeInterval(1)
            return
        }
        guard reference >= nextSummaryDeadline else { return }
        let snapshot = hudSnapshot(reference: reference)
        logger.log(
            "overlay_hud events_per_sec=\(snapshot.eventsPerSecond, format: .fixed(precision: 1), privacy: .public) updates_per_sec=\(snapshot.updatesPerSecond, format: .fixed(precision: 1), privacy: .public) avg_update_ms=\(snapshot.averageUpdateDuration * 1000, format: .fixed(precision: 2), privacy: .public) p95_update_ms=\(snapshot.p95UpdateDuration * 1000, format: .fixed(precision: 2), privacy: .public) avg_event_to_update_ms=\(snapshot.averageEventToUpdateDelay * 1000, format: .fixed(precision: 2), privacy: .public) coalesced_per_update=\(snapshot.averageCoalescedEventsPerUpdate, format: .fixed(precision: 2), privacy: .public) avg_mask_build_ms=\(snapshot.averageMaskBuildDuration * 1000, format: .fixed(precision: 2), privacy: .public) p95_mask_build_ms=\(snapshot.p95MaskBuildDuration * 1000, format: .fixed(precision: 2), privacy: .public) avg_layer_apply_ms=\(snapshot.averageLayerApplyDuration * 1000, format: .fixed(precision: 2), privacy: .public) p95_layer_apply_ms=\(snapshot.p95LayerApplyDuration * 1000, format: .fixed(precision: 2), privacy: .public) mode=\(snapshot.mode, privacy: .public) fallback=\(snapshot.lastFallbackReason, privacy: .public) diagnosis=\(snapshot.diagnosis?.rawValue ?? "n/a", privacy: .public)"
        )
        nextSummaryDeadline = reference.addingTimeInterval(1)
    }

    /// Maps low-level update reasons into coarse event source buckets.
    private func eventSource(for reason: UpdateCoordinator.Reason) -> EventSource {
        switch reason {
        case .activeApplicationChanged:
            return .activeAppChange
        case .windowInteractionBegan, .windowInteractionChanged, .windowInteractionEnded, .activeWindowChanged:
            return .windowMoveResize
        case .screenConfigurationChanged:
            return .screenChange
        case .spaceChanged:
            return .spaceChange
        case .workspaceAnimation:
            return .workspaceAnimation
        case .manualRefresh:
            return .manualRefresh
        }
    }

    /// Infers a high-level diagnosis from current event and update characteristics.
    private func diagnosis(from eventsPerSecond: Double, updatesPerSecond: Double, averageUpdateDuration: TimeInterval) -> Diagnosis? {
        if currentMode != "fast", lastFallbackReason != "none" {
            return .fallbackModeCadence
        }
        if eventsPerSecond >= 8, updatesPerSecond <= max(1.5, eventsPerSecond * 0.25) {
            return .schedulerStarvation
        }
        if updatesPerSecond >= 6, averageUpdateDuration >= 0.08 {
            return .slowMaskPipeline
        }
        return nil
    }

    /// Keeps only the most recent one-second sample window for all tracked metrics.
    private func trimSamples(reference: Date) {
        let cutoff = reference.addingTimeInterval(-1)
        eventTimestamps.removeAll { $0 < cutoff }
        updateStartTimestamps.removeAll { $0 < cutoff }
        updateDurations.removeAll { $0.timestamp < cutoff }
        eventToUpdateDelays.removeAll { $0.timestamp < cutoff }
        coalescedEventsPerUpdate.removeAll { $0.timestamp < cutoff }
        maskBuildDurations.removeAll { $0.timestamp < cutoff }
        layerApplyDurations.removeAll { $0.timestamp < cutoff }
    }

    /// Computes the arithmetic mean for a timed sample stream.
    private func average(of samples: [TimedValue]) -> TimeInterval {
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(0.0) { partial, sample in
            partial + sample.value
        }
        return total / Double(samples.count)
    }

    /// Returns a clamped percentile value from the provided timed sample stream.
    private func percentile(of samples: [TimedValue], percentile: Double) -> TimeInterval {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.map(\.value).sorted()
        let clampedPercentile = min(max(percentile, 0), 1)
        let index = min(max(Int((Double(sorted.count - 1) * clampedPercentile).rounded()), 0), sorted.count - 1)
        return sorted[index]
    }
}
