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
    }

    struct Configuration {
        var debounceInterval: TimeInterval = 0.045
        var interactionDebounceInterval: TimeInterval = 1.0 / 30.0
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
    private var scheduledDispatchTask: Task<Void, Never>?
    private var runningUpdateTask: Task<Void, Never>?
    private var isInteractionActive = false

    private var totalEventsInBurst = 0
    private var totalUpdatesInBurst = 0
    private var burstDeadline = Date.distantPast

    private var recentUpdateTimestamps: [Date] = []

    init(performUpdate: @escaping (Work) async -> Void) {
        self.performUpdate = performUpdate
    }

    func requestUpdate(reason: Reason) {
        latestGeneration &+= 1
        let generation = latestGeneration

        pendingReasons.insert(reason)
        pendingEventCount += 1
        totalEventsInBurst += 1
        if burstDeadline == .distantPast {
            burstDeadline = Date().addingTimeInterval(1.5)
        }

        switch reason {
        case .windowInteractionBegan, .windowInteractionChanged:
            isInteractionActive = true
        case .windowInteractionEnded:
            isInteractionActive = false
        default:
            break
        }

        if state == .updating {
            runningUpdateTask?.cancel()
        }

        scheduleDispatch(for: reason, generation: generation)
    }

    func isGenerationCurrent(_ generation: Int) -> Bool {
        generation == latestGeneration
    }

    private func scheduleDispatch(for reason: Reason, generation: Int) {
        scheduledDispatchTask?.cancel()
        let delay = dispatchDelay(for: reason)
        state = .pending
        scheduledDispatchTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                let duration = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: duration)
            }
            await self.dispatchIfCurrent(generation: generation)
        }
    }

    private func dispatchDelay(for reason: Reason) -> TimeInterval {
        switch reason {
        case .windowInteractionEnded:
            return 0
        case .windowInteractionBegan, .windowInteractionChanged:
            return configuration.interactionDebounceInterval
        default:
            return configuration.debounceInterval
        }
    }

    private func dispatchIfCurrent(generation: Int) async {
        guard generation == latestGeneration else { return }
        guard !pendingReasons.isEmpty else {
            state = .idle
            return
        }

        let reasons = pendingReasons
        let coalescedEventCount = pendingEventCount
        pendingReasons.removeAll()
        pendingEventCount = 0
        scheduledDispatchTask = nil
        state = .updating

        let work = Work(generation: generation, reasons: reasons)
        let startedAt = Date()
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
            scheduleDispatch(for: .manualRefresh, generation: latestGeneration)
        }
    }

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
