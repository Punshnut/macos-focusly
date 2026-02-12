import XCTest
@testable import Focusly

private actor OverlayDiagnosticMetrics {
    private(set) var eventCount = 0
    private(set) var updateCount = 0
    private(set) var totalCoalescedEvents = 0
    private(set) var updateDurations: [TimeInterval] = []
    private(set) var eventToUpdateDelays: [TimeInterval] = []
    private(set) var updateStartTimestamps: [Date] = []

    func recordEvent() {
        eventCount += 1
    }

    func recordUpdateStart(work: UpdateCoordinator.Work, startedAt: Date) {
        updateCount += 1
        totalCoalescedEvents += work.coalescedEventCount
        eventToUpdateDelays.append(max(0, startedAt.timeIntervalSince(work.firstEventAt)))
        updateStartTimestamps.append(startedAt)
    }

    func recordUpdateDuration(_ duration: TimeInterval) {
        updateDurations.append(max(0, duration))
    }
}

final class OverlayDiagnosticsProtocolTests: XCTestCase {
    func testDiagnosticProtocolRestoresLiveCadenceDuringInteractionBurst() async throws {
        let metrics = OverlayDiagnosticMetrics()

        let coordinator = await MainActor.run {
            let coordinator = UpdateCoordinator { work in
                let startedAt = Date()
                await metrics.recordUpdateStart(work: work, startedAt: startedAt)
                try? await Task.sleep(nanoseconds: 2_000_000)
                await metrics.recordUpdateDuration(Date().timeIntervalSince(startedAt))
            }
            var configuration = coordinator.configuration
            configuration.throttleInterval = 1.0 / 60.0
            configuration.interactionThrottleInterval = 1.0 / 30.0
            configuration.trailingUpdateDelay = 0.1
            coordinator.configuration = configuration
            return coordinator
        }

        try await runEventPhase(
            reason: .activeApplicationChanged,
            interval: 0.015,
            duration: 2.0,
            coordinator: coordinator,
            metrics: metrics
        )

        let dragStartedAt = Date()
        await MainActor.run {
            coordinator.requestUpdate(reason: .windowInteractionBegan)
        }
        await metrics.recordEvent()

        try await runEventPhase(
            reason: .windowInteractionChanged,
            interval: 0.010,
            duration: 5.0,
            coordinator: coordinator,
            metrics: metrics
        )

        await MainActor.run {
            coordinator.requestUpdate(reason: .windowInteractionEnded)
        }
        await metrics.recordEvent()
        let dragEndedAt = Date()

        try await runBurst(reason: .screenConfigurationChanged, repetitions: 6, coordinator: coordinator, metrics: metrics)
        try await runBurst(reason: .spaceChanged, repetitions: 6, coordinator: coordinator, metrics: metrics)
        try await runBurst(reason: .manualRefresh, repetitions: 4, coordinator: coordinator, metrics: metrics)
        try await Task.sleep(nanoseconds: 450_000_000)

        let events = await metrics.eventCount
        let updates = await metrics.updateCount
        let updateDurations = await metrics.updateDurations
        let eventToUpdateDelays = await metrics.eventToUpdateDelays
        let updateStartTimestamps = await metrics.updateStartTimestamps
        let avgDuration = average(updateDurations)
        let p95Duration = percentile95(updateDurations)
        let avgDelay = average(eventToUpdateDelays)
        let coalesced = await metrics.totalCoalescedEvents
        let avgCoalescedPerUpdate = updates > 0 ? Double(coalesced) / Double(updates) : 0

        let dragUpdates = updateStartTimestamps.filter { $0 >= dragStartedAt && $0 <= dragEndedAt }.count
        let dragDuration = max(dragEndedAt.timeIntervalSince(dragStartedAt), 0.001)
        let dragUpdatesPerSecond = Double(dragUpdates) / dragDuration

        print(
            "diagnostic protocol: events=\(events) updates=\(updates) drag_updates_per_sec=\(String(format: "%.2f", dragUpdatesPerSecond)) " +
            "avg_update_ms=\(String(format: "%.2f", avgDuration * 1000)) p95_update_ms=\(String(format: "%.2f", p95Duration * 1000)) " +
            "avg_event_to_update_ms=\(String(format: "%.2f", avgDelay * 1000)) avg_coalesced=\(String(format: "%.2f", avgCoalescedPerUpdate))"
        )

        XCTAssertGreaterThanOrEqual(dragUpdatesPerSecond, 25)
        XCTAssertLessThanOrEqual(dragUpdatesPerSecond, 65)
        XCTAssertLessThan(avgDelay * 1000, 120)
    }

    private func runEventPhase(
        reason: UpdateCoordinator.Reason,
        interval: TimeInterval,
        duration: TimeInterval,
        coordinator: UpdateCoordinator,
        metrics: OverlayDiagnosticMetrics
    ) async throws {
        let endTime = Date().addingTimeInterval(duration)
        while Date() < endTime {
            await MainActor.run {
                coordinator.requestUpdate(reason: reason)
            }
            await metrics.recordEvent()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    private func runBurst(
        reason: UpdateCoordinator.Reason,
        repetitions: Int,
        coordinator: UpdateCoordinator,
        metrics: OverlayDiagnosticMetrics
    ) async throws {
        for _ in 0..<repetitions {
            await MainActor.run {
                coordinator.requestUpdate(reason: reason)
            }
            await metrics.recordEvent()
            try await Task.sleep(nanoseconds: 18_000_000)
        }
        try await Task.sleep(nanoseconds: 120_000_000)
    }

    private func average(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let total = values.reduce(0, +)
        return total / Double(values.count)
    }

    private func percentile95(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(max(Int((Double(sorted.count - 1) * 0.95).rounded()), 0), sorted.count - 1)
        return sorted[index]
    }
}
