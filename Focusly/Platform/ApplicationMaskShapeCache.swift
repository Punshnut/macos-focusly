import AppKit

/// Lightweight cache that remembers supplementary mask geometry per application so
/// background snapshots can be primed without re-scanning the entire window list.
@MainActor
final class ApplicationMaskShapeCache {
    static let shared = ApplicationMaskShapeCache()

    private struct Entry {
        var frame: NSRect
        var regions: [ActiveWindowSnapshot.MaskRegion]
        var timestamp: Date
    }

    private var entries: [pid_t: Entry] = [:]
    private let entryLifetime: TimeInterval = 1.8
    private let maximumEntries = 24
    private let defaultFrameTolerance: CGFloat = 18

    /// Stores the latest supplementary mask regions for the owning process.
    func record(snapshot: ActiveWindowSnapshot) {
        guard let pid = snapshot.ownerPID else { return }
        pruneExpiredEntries()
        guard !snapshot.supplementaryMasks.isEmpty else {
            entries.removeValue(forKey: pid)
            return
        }

        entries[pid] = Entry(frame: snapshot.frame, regions: snapshot.supplementaryMasks, timestamp: Date())
        if entries.count > maximumEntries {
            dropOldestEntries()
        }
    }

    /// Returns cached supplementary regions for a process when the anchor frame still matches.
    func cachedSupplementaryMasks(forPID pid: pid_t, matching frame: NSRect) -> [ActiveWindowSnapshot.MaskRegion]? {
        pruneExpiredEntries()
        guard let entry = entries[pid] else { return nil }

        let tolerance = max(
            defaultFrameTolerance,
            min(frame.width, frame.height) * 0.06
        )
        guard entry.frame.isApproximatelyEqual(to: frame, tolerance: tolerance) else { return nil }
        return entry.regions
    }

    private func pruneExpiredEntries() {
        let cutoff = Date().addingTimeInterval(-entryLifetime)
        entries = entries.filter { $0.value.timestamp >= cutoff }
    }

    private func dropOldestEntries() {
        guard entries.count > maximumEntries else { return }
        let sorted = entries.sorted { lhs, rhs in
            lhs.value.timestamp < rhs.value.timestamp
        }
        let excess = sorted.prefix(sorted.count - maximumEntries)
        for pair in excess {
            entries.removeValue(forKey: pair.key)
        }
    }
}
