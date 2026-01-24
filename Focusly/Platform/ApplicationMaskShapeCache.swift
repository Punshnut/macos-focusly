import AppKit

/// Lightweight cache that remembers supplementary mask geometry per application so
/// background snapshots can be primed without re-scanning the entire window list.
@MainActor
final class ApplicationMaskShapeCache {
    static let shared = ApplicationMaskShapeCache()

    private struct Entry {
        let signature: Int
        var frame: NSRect
        var cornerRadius: CGFloat
        var regions: [ActiveWindowSnapshot.MaskRegion]
        var timestamp: Date
    }

    private var entries: [pid_t: [Entry]] = [:]
    private let entryLifetime: TimeInterval = 2.8
    private let maximumEntries = 36
    private let maximumEntriesPerProcess = 4
    private let defaultFrameTolerance: CGFloat = 18

    /// Stores the latest supplementary mask regions for the owning process.
    func record(snapshot: ActiveWindowSnapshot) {
        guard let pid = snapshot.ownerPID else { return }
        pruneExpiredEntries()
        guard !snapshot.supplementaryMasks.isEmpty else {
            entries.removeValue(forKey: pid)
            return
        }

        let signature = Self.signature(for: snapshot.frame)
        var bucket = entries[pid] ?? []
        bucket.removeAll { $0.signature == signature }
        bucket.insert(Entry(
            signature: signature,
            frame: snapshot.frame,
            cornerRadius: snapshot.cornerRadius,
            regions: snapshot.supplementaryMasks,
            timestamp: Date()
        ), at: 0)

        if bucket.count > maximumEntriesPerProcess {
            bucket = Array(bucket.prefix(maximumEntriesPerProcess))
        }
        entries[pid] = bucket
        dropOldestEntries()
    }

    /// Returns cached supplementary regions for a process when the anchor frame still matches.
    func cachedSupplementaryMasks(forPID pid: pid_t, matching frame: NSRect) -> [ActiveWindowSnapshot.MaskRegion]? {
        pruneExpiredEntries()
        guard let bucket = entries[pid], !bucket.isEmpty else { return nil }

        let signature = Self.signature(for: frame)
        let tightTolerance = max(
            defaultFrameTolerance,
            min(frame.width, frame.height) * 0.06
        )
        let looseTolerance = tightTolerance * 1.8

        if let direct = bucket.first(where: { $0.signature == signature && $0.frame.isApproximatelyEqual(to: frame, tolerance: tightTolerance) }) {
            return direct.regions
        }

        if let fuzzy = bucket.first(where: { $0.frame.isApproximatelyEqual(to: frame, tolerance: looseTolerance) }) {
            return fuzzy.regions
        }

        if let fallback = bucket.first {
            let frameArea = max(frame.width * frame.height, .ulpOfOne)
            let ratio = (fallback.frame.width * fallback.frame.height) / frameArea
            if ratio >= 0.5 && ratio <= 1.8 {
                return fallback.regions
            }
        }

        return nil
    }

    /// Returns the cached corner radius for a process when the frame still matches.
    func cachedCornerRadius(forPID pid: pid_t, matching frame: NSRect) -> CGFloat? {
        pruneExpiredEntries()
        guard let bucket = entries[pid], !bucket.isEmpty else { return nil }
        let signature = Self.signature(for: frame)
        let tolerance = max(
            defaultFrameTolerance,
            min(frame.width, frame.height) * 0.08
        )

        if let direct = bucket.first(where: { $0.signature == signature && $0.frame.isApproximatelyEqual(to: frame, tolerance: tolerance) }) {
            return direct.cornerRadius
        }

        if let fuzzy = bucket.first(where: { $0.frame.isApproximatelyEqual(to: frame, tolerance: tolerance * 1.5) }) {
            return fuzzy.cornerRadius
        }

        return bucket.first?.cornerRadius
    }

    private func pruneExpiredEntries() {
        let cutoff = Date().addingTimeInterval(-entryLifetime)
        entries = entries
            .mapValues { bucket in
                bucket.filter { $0.timestamp >= cutoff }
            }
            .filter { !$0.value.isEmpty }
    }

    private func dropOldestEntries() {
        var flat: [(pid: pid_t, entry: Entry)] = []
        for (pid, bucket) in entries {
            for entry in bucket {
                flat.append((pid, entry))
            }
        }
        guard flat.count > maximumEntries else { return }
        flat.sort { $0.entry.timestamp > $1.entry.timestamp }
        let trimmed = Array(flat.prefix(maximumEntries))
        var rebuilt: [pid_t: [Entry]] = [:]
        for pair in trimmed {
            var bucket = rebuilt[pair.pid] ?? []
            bucket.append(pair.entry)
            rebuilt[pair.pid] = bucket
        }
        entries = rebuilt
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
}
