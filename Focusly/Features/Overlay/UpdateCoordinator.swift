import Foundation
import os.log

/// Orchestrates overlay updates from event streams, coalescing bursts and dropping stale work.
@MainActor
final class UpdateCoordinator {
    enum Reason: String, Hashable {
        case activeApplicationChanged
        case activeWindowChanged
        case windowInteractionBegan
        case windowInteractionChanged
        case windowInteractionEnded
        case screenConfigurationChanged
        case spaceChanged
        case workspaceAnimation
        case manualRefresh
    }

    enum State {
        case idle
        case pending
        case updating
    }

    struct WatchdogEvent {
        enum Kind {
            case updateDurationExceeded
            case updateRateExceeded
        }

        let kind: Kind
        let timestamp: Date
        let measuredValue: Double
        let threshold: Double
        let reasons: Set<Reason>
    }

    struct Work {
        let generation: Int
        let reasons: Set<Reason>
        let coalescedEventCount: Int
        let firstEventAt: Date
        let requestedAt: Date
    }

    struct Configuration {
        var throttleInterval: TimeInterval = 1.0 / 60.0
        var interactionThrottleInterval: TimeInterval = 1.0 / 30.0
        var trailingUpdateDelay: TimeInterval = 0.1
        var updateDurationWatchdogThreshold: TimeInterval = 0.18
        var updateRateWatchdogThreshold: Double = 24
    }

    private let logger = Logger(subsystem: "com.focusly.app", category: "UpdateCoordinator")
    private let performUpdate: (Work) async -> Void
    private(set) var state: State = .idle
    private(set) var latestGeneration: Int = 0
    var configuration = Configuration()
    var onWatchdogEscalation: ((WatchdogEvent) -> Void)?

    private var pendingReasons: Set<Reason> = []
    private var pendingEventCount = 0
    private var pendingFirstEventAt: Date?
    private var pendingLastRequestedAt: Date?
    private var scheduledThrottleTask: Task<Void, Never>?
    private var scheduledTrailingTask: Task<Void, Never>?
    private var runningUpdateTask: Task<Void, Never>?
    private var isInteractionActive = false
    private var lastUpdateStartedAt: Date = .distantPast
    private var throttleScheduleToken: Int = 0
    private var trailingScheduleToken: Int = 0
    private var trailingFallbackTimestamp: Date?

    private var totalEventsInBurst = 0
    private var totalUpdatesInBurst = 0
    private var burstDeadline = Date.distantPast

    private var recentUpdateTimestamps: [Date] = []

    init(performUpdate: @escaping (Work) async -> Void) {
        self.performUpdate = performUpdate
    }

    /// Enqueues an update reason and schedules leading/trailing dispatch work as needed.
    func requestUpdate(reason: Reason) {
        latestGeneration &+= 1
        let eventTimestamp = Date()

        pendingReasons.insert(reason)
        pendingEventCount += 1
        if pendingFirstEventAt == nil {
            pendingFirstEventAt = eventTimestamp
        }
        pendingLastRequestedAt = eventTimestamp
        totalEventsInBurst += 1
        if burstDeadline == .distantPast {
            burstDeadline = eventTimestamp.addingTimeInterval(1.5)
        }

        switch reason {
        case .windowInteractionBegan, .windowInteractionChanged:
            isInteractionActive = true
        case .windowInteractionEnded:
            isInteractionActive = false
        default:
            break
        }

        scheduleTrailingDispatch(lastEventAt: eventTimestamp)
        triggerLeadingOrThrottledDispatch(referenceTime: eventTimestamp)
    }

    /// Guards async work so stale generations can be discarded by callers.
    func isGenerationCurrent(_ generation: Int) -> Bool {
        generation == latestGeneration
    }

    /// Chooses immediate dispatch or a throttled delayed dispatch based on recent cadence.
    private func triggerLeadingOrThrottledDispatch(referenceTime: Date) {
        let throttle = activeThrottleInterval()
        let elapsed = referenceTime.timeIntervalSince(lastUpdateStartedAt)
        if state != .updating, (lastUpdateStartedAt == .distantPast || elapsed >= throttle) {
            scheduledThrottleTask?.cancel()
            scheduledThrottleTask = nil
            Task { [weak self] in
                await self?.dispatchPendingUpdate()
            }
            return
        }

        let dueDate: Date
        if lastUpdateStartedAt == .distantPast {
            dueDate = referenceTime
        } else {
            dueDate = lastUpdateStartedAt.addingTimeInterval(throttle)
        }
        scheduleThrottleDispatch(at: dueDate)
    }

    /// Returns the current throttle interval, switching to the interaction cadence during drags.
    private func activeThrottleInterval() -> TimeInterval {
        let interval = isInteractionActive
            ? configuration.interactionThrottleInterval
            : configuration.throttleInterval
        return max(1.0 / 240.0, interval)
    }

    /// Schedules the next throttled dispatch and invalidates older throttle tasks.
    private func scheduleThrottleDispatch(at dueDate: Date) {
        throttleScheduleToken &+= 1
        let token = throttleScheduleToken
        scheduledThrottleTask?.cancel()
        state = .pending
        scheduledThrottleTask = Task { [weak self] in
            guard let self else { return }
            let delay = max(0, dueDate.timeIntervalSinceNow)
            if delay > 0 {
                let duration = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: duration)
            }
            await self.dispatchThrottledIfCurrent(token: token)
        }
    }

    /// Runs the throttled dispatch only if its token is still current.
    private func dispatchThrottledIfCurrent(token: Int) async {
        guard token == throttleScheduleToken else { return }
        scheduledThrottleTask = nil
        await dispatchPendingUpdate()
    }

    /// Schedules a trailing refresh so short bursts still produce a final stable frame.
    private func scheduleTrailingDispatch(lastEventAt: Date) {
        trailingFallbackTimestamp = lastEventAt
        trailingScheduleToken &+= 1
        let token = trailingScheduleToken
        scheduledTrailingTask?.cancel()
        scheduledTrailingTask = Task { [weak self] in
            guard let self else { return }
            let delay = max(0.08, min(self.configuration.trailingUpdateDelay, 0.12))
            let duration = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: duration)
            await self.dispatchTrailingIfCurrent(token: token)
        }
    }

    /// Executes trailing dispatch and synthesizes a manual refresh when no reasons remain.
    private func dispatchTrailingIfCurrent(token: Int) async {
        guard token == trailingScheduleToken else { return }
        scheduledTrailingTask = nil
        if pendingReasons.isEmpty {
            latestGeneration &+= 1
            pendingReasons.insert(.manualRefresh)
            pendingEventCount = 1
            let timestamp = trailingFallbackTimestamp ?? Date()
            pendingFirstEventAt = timestamp
            pendingLastRequestedAt = timestamp
        }
        await dispatchPendingUpdate()
    }

    /// Drains pending reasons into one coalesced work item and executes the update closure.
    private func dispatchPendingUpdate() async {
        if state == .updating {
            return
        }
        guard !pendingReasons.isEmpty else {
            state = .idle
            return
        }

        let reasons = pendingReasons
        let coalescedEventCount = pendingEventCount
        let firstEventAt = pendingFirstEventAt ?? Date()
        let requestedAt = pendingLastRequestedAt ?? firstEventAt
        pendingReasons.removeAll()
        pendingEventCount = 0
        pendingFirstEventAt = nil
        pendingLastRequestedAt = nil
        state = .updating
        lastUpdateStartedAt = Date()

        let work = Work(
            generation: latestGeneration,
            reasons: reasons,
            coalescedEventCount: coalescedEventCount,
            firstEventAt: firstEventAt,
            requestedAt: requestedAt
        )
        let startedAt = lastUpdateStartedAt
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performUpdate(work)
        }
        runningUpdateTask = task
        await task.value

        runningUpdateTask = nil
        totalUpdatesInBurst += 1
        let duration = Date().timeIntervalSince(startedAt)

        if coalescedEventCount > 1 {
            logger.log("coalesced \(coalescedEventCount, privacy: .public) events -> 1 update")
        }
        maybeLogBurstSummary()
        evaluateWatchdog(duration: duration, reasons: reasons)

        if pendingReasons.isEmpty {
            state = .idle
        } else {
            state = .pending
            triggerLeadingOrThrottledDispatch(referenceTime: Date())
        }
    }

    /// Emits a periodic coalescing summary for diagnostic visibility during event bursts.
    private func maybeLogBurstSummary() {
        let now = Date()
        guard burstDeadline != .distantPast else { return }
        guard now >= burstDeadline else { return }
        if totalEventsInBurst > totalUpdatesInBurst {
            logger.log(
                "coalesced \(self.totalEventsInBurst, privacy: .public) events -> \(self.totalUpdatesInBurst, privacy: .public) updates"
            )
        }
        totalEventsInBurst = 0
        totalUpdatesInBurst = 0
        burstDeadline = .distantPast
    }

    /// Triggers watchdog callbacks when update duration or update rate exceed configured thresholds.
    private func evaluateWatchdog(duration: TimeInterval, reasons: Set<Reason>) {
        let now = Date()
        if duration > configuration.updateDurationWatchdogThreshold {
            onWatchdogEscalation?(
                WatchdogEvent(
                    kind: .updateDurationExceeded,
                    timestamp: now,
                    measuredValue: duration,
                    threshold: configuration.updateDurationWatchdogThreshold,
                    reasons: reasons
                )
            )
        }

        recentUpdateTimestamps.append(now)
        recentUpdateTimestamps.removeAll { now.timeIntervalSince($0) > 1.0 }
        let rate = Double(recentUpdateTimestamps.count)
        if rate > configuration.updateRateWatchdogThreshold {
            onWatchdogEscalation?(
                WatchdogEvent(
                    kind: .updateRateExceeded,
                    timestamp: now,
                    measuredValue: rate,
                    threshold: configuration.updateRateWatchdogThreshold,
                    reasons: reasons
                )
            )
        }
    }
}
