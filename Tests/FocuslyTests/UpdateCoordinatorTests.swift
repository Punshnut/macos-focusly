import XCTest
@testable import Focusly

private actor UpdateCounter {
    private(set) var updates = 0

    func increment() {
        updates += 1
    }
}

final class UpdateCoordinatorTests: XCTestCase {
    func testCoalescesResizeBurstsIntoCappedUpdates() async throws {
        let counter = UpdateCounter()

        let coordinator = await MainActor.run {
            let scheduler = UpdateCoordinator { _ in
                await counter.increment()
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
            var configuration = scheduler.configuration
            configuration.debounceInterval = 0.03
            configuration.interactionDebounceInterval = 0.03
            scheduler.configuration = configuration
            return scheduler
        }

        for _ in 0..<3 {
            await MainActor.run {
                for _ in 0..<8 {
                    coordinator.requestUpdate(reason: .windowInteractionChanged)
                }
            }
            try await Task.sleep(nanoseconds: 55_000_000)
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        let updateCount = await counter.updates
        print("coalesced 24 resize events -> \(updateCount) updates")
        XCTAssertGreaterThanOrEqual(updateCount, 2)
        XCTAssertLessThanOrEqual(updateCount, 4)
    }
}
