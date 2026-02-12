import XCTest
@testable import Focusly

private actor UpdateCounter {
    private(set) var updates = 0
    private(set) var timestamps: [Date] = []

    func increment() {
        updates += 1
        timestamps.append(Date())
    }
}

final class UpdateCoordinatorTests: XCTestCase {
    func testLeadingEdgeDispatchesImmediately() async throws {
        let counter = UpdateCounter()
        let firstEventAt = Date()

        let coordinator = await MainActor.run {
            let scheduler = UpdateCoordinator { _ in
                await counter.increment()
            }
            var configuration = scheduler.configuration
            configuration.throttleInterval = 0.04
            configuration.interactionThrottleInterval = 0.04
            configuration.trailingUpdateDelay = 0.1
            scheduler.configuration = configuration
            return scheduler
        }

        await MainActor.run {
            coordinator.requestUpdate(reason: .manualRefresh)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let timestamps = await counter.timestamps
        XCTAssertFalse(timestamps.isEmpty)
        let delay = timestamps[0].timeIntervalSince(firstEventAt)
        XCTAssertLessThan(delay, 0.03)
    }

    func testInteractionBurstsAreThrottledAndTrailingUpdateFires() async throws {
        let counter = UpdateCounter()

        let coordinator = await MainActor.run {
            let scheduler = UpdateCoordinator { _ in
                await counter.increment()
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            var configuration = scheduler.configuration
            configuration.throttleInterval = 1.0 / 60.0
            configuration.interactionThrottleInterval = 1.0 / 30.0
            configuration.trailingUpdateDelay = 0.1
            scheduler.configuration = configuration
            return scheduler
        }

        await MainActor.run {
            coordinator.requestUpdate(reason: .windowInteractionBegan)
        }
        let burstEnd = Date().addingTimeInterval(0.5)
        while Date() < burstEnd {
            await MainActor.run {
                coordinator.requestUpdate(reason: .windowInteractionChanged)
            }
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        await MainActor.run {
            coordinator.requestUpdate(reason: .windowInteractionEnded)
        }
        try await Task.sleep(nanoseconds: 250_000_000)

        let updateCount = await counter.updates
        print("interaction burst updates=\(updateCount)")
        XCTAssertGreaterThanOrEqual(updateCount, 8)   // ~30 Hz over 0.5s plus leading/trailing
        XCTAssertLessThanOrEqual(updateCount, 24)     // should remain capped, not per-event
    }
}
