import Foundation
import OSLog

/// Lightweight runtime diagnostics for timing and event counters.
enum PerformanceDiagnostics {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var counters: [String: Int] = [:]
        var durationTotalsNs: [String: UInt64] = [:]
        var durationCounts: [String: Int] = [:]
        var lastSummaryDate = Date.distantPast
    }

    private static let logger = Logger(subsystem: "com.focusly.app", category: "Performance")
    private static let envToggleKey = "FOCUSLY_PERF_DIAGNOSTICS"
    private static let defaultsToggleKey = "Focusly.PerformanceDiagnosticsEnabled"
    private static let slowOperationThresholdMs = 1.5
    private static let summaryInterval: TimeInterval = 8
    private static let storage = Storage()

    /// Returns true when diagnostics are enabled by environment or user defaults.
    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment[envToggleKey] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: defaultsToggleKey)
    }

    /// Starts timing an operation and returns a token to pass to `end`.
    static func begin() -> UInt64? {
        guard isEnabled else { return nil }
        return DispatchTime.now().uptimeNanoseconds
    }

    /// Finishes a timed operation and records aggregate duration metrics.
    static func end(_ startToken: UInt64?, operation: String) {
        guard let startToken, isEnabled else { return }
        let end = DispatchTime.now().uptimeNanoseconds
        let elapsed = end &- startToken
        recordDuration(operation: operation, nanoseconds: elapsed)
        maybeEmitSummary()
    }

    /// Increments a named counter used in periodic performance summaries.
    static func increment(_ key: String, by amount: Int = 1) {
        guard isEnabled else { return }
        storage.lock.lock()
        storage.counters[key, default: 0] += amount
        storage.lock.unlock()
        maybeEmitSummary()
    }

    /// Records a cache hit/miss pair under a shared metric key.
    static func recordCache(key: String, hit: Bool) {
        increment(hit ? "\(key).hit" : "\(key).miss")
    }

    /// Stores operation duration totals/counts and logs unusually slow individual samples.
    private static func recordDuration(operation: String, nanoseconds: UInt64) {
        storage.lock.lock()
        storage.durationTotalsNs[operation, default: 0] &+= nanoseconds
        storage.durationCounts[operation, default: 0] += 1
        storage.lock.unlock()

        let elapsedMs = Double(nanoseconds) / 1_000_000
        if elapsedMs >= slowOperationThresholdMs {
            logger.debug("\(operation, privacy: .public) took \(elapsedMs, format: .fixed(precision: 3), privacy: .public) ms")
        }
    }

    /// Emits periodic rolled-up metrics to the unified logger.
    private static func maybeEmitSummary() {
        guard isEnabled else { return }
        let now = Date()
        storage.lock.lock()
        guard now.timeIntervalSince(storage.lastSummaryDate) >= summaryInterval else {
            storage.lock.unlock()
            return
        }
        let snapshotCounters = storage.counters
        let snapshotTotals = storage.durationTotalsNs
        let snapshotCounts = storage.durationCounts
        storage.counters.removeAll(keepingCapacity: true)
        storage.durationTotalsNs.removeAll(keepingCapacity: true)
        storage.durationCounts.removeAll(keepingCapacity: true)
        storage.lastSummaryDate = now
        storage.lock.unlock()

        guard !snapshotCounters.isEmpty || !snapshotCounts.isEmpty else { return }

        let topCounters = snapshotCounters
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")

        let topDurations = snapshotCounts
            .compactMap { key, count -> String? in
                guard count > 0, let total = snapshotTotals[key] else { return nil }
                let avgMs = (Double(total) / Double(count)) / 1_000_000
                return "\(key):avg=\(String(format: "%.3f", avgMs))ms n=\(count)"
            }
            .sorted()
            .prefix(8)
            .joined(separator: ", ")

        logger.debug("Perf summary counters[\(topCounters, privacy: .public)] durations[\(topDurations, privacy: .public)]")
    }
}
