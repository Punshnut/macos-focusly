import AppKit

/// Lightweight cache that remembers supplementary mask geometry per application so
/// background snapshots can be primed without re-scanning the entire window list.
@MainActor
final class ApplicationMaskShapeCache {
    static let shared = ApplicationMaskShapeCache()

    private enum CacheKey: Hashable {
        case process(pid_t)
        case application(String)
    }

    private struct ProcessDescriptor {
        let bundleIdentifier: String?
        let timestamp: Date
    }

    private struct Entry {
        let signature: Int
        var frame: NSRect
        var cornerRadius: CGFloat
        var regions: [ActiveWindowSnapshot.MaskRegion]
        var timestamp: Date
    }

    private var entries: [CacheKey: [Entry]] = [:]
    private var processDescriptors: [pid_t: ProcessDescriptor] = [:]
    private let entryLifetime: TimeInterval = 8
    private let processDescriptorLifetime: TimeInterval = 30
    private let maximumEntries = 56
    private let maximumEntriesPerProcess = 4
    private let maximumEntriesPerApplication = 10
    private let defaultFrameTolerance: CGFloat = 18

    /// Stores the latest supplementary mask regions for the owning process.
    func record(snapshot: ActiveWindowSnapshot) {
        guard let pid = snapshot.ownerPID else { return }
        pruneExpiredEntries()
        pruneExpiredProcessDescriptors()
        let keys = cacheKeys(for: pid)

        guard !snapshot.supplementaryMasks.isEmpty else {
            entries[.process(pid)] = nil
            return
        }

        let signature = Self.signature(for: snapshot.frame)
        let now = Date()
        let latestEntry = Entry(
            signature: signature,
            frame: snapshot.frame,
            cornerRadius: snapshot.cornerRadius,
            regions: snapshot.supplementaryMasks,
            timestamp: now
        )

        for key in keys {
            var bucket = entries[key] ?? []
            if let first = bucket.first,
               first.signature == signature,
               first.frame.isApproximatelyEqual(to: snapshot.frame, tolerance: 0.5),
               abs(first.cornerRadius - snapshot.cornerRadius) <= 0.5,
               first.regions == snapshot.supplementaryMasks {
                bucket[0] = Entry(
                    signature: first.signature,
                    frame: first.frame,
                    cornerRadius: first.cornerRadius,
                    regions: first.regions,
                    timestamp: now
                )
                entries[key] = bucket
                continue
            }
            bucket.removeAll { $0.signature == signature }
            bucket.insert(latestEntry, at: 0)
            let limit = maximumEntriesPerKey(for: key)
            if bucket.count > limit {
                bucket = Array(bucket.prefix(limit))
            }
            entries[key] = bucket
        }

        dropOldestEntries()
    }

    /// Returns cached supplementary regions for a process when the anchor frame still matches.
    func cachedSupplementaryMasks(
        forPID pid: pid_t,
        matching frame: NSRect,
        maximumAge: TimeInterval? = nil
    ) -> [ActiveWindowSnapshot.MaskRegion]? {
        pruneExpiredEntries()
        pruneExpiredProcessDescriptors()
        for key in cacheKeys(for: pid) {
            guard let bucket = entries[key], !bucket.isEmpty else { continue }
            if let match = bestMatch(in: bucket, for: frame) {
                if let maximumAge,
                   Date().timeIntervalSince(match.timestamp) > maximumAge {
                    continue
                }
                return match.regions
            }
        }
        return nil
    }

    /// Returns the cached corner radius for a process when the frame still matches.
    func cachedCornerRadius(forPID pid: pid_t, matching frame: NSRect) -> CGFloat? {
        pruneExpiredEntries()
        pruneExpiredProcessDescriptors()
        for key in cacheKeys(for: pid) {
            guard let bucket = entries[key], !bucket.isEmpty else { continue }
            if let match = bestMatch(in: bucket, for: frame) {
                return match.cornerRadius
            }
        }
        return nil
    }

    private func pruneExpiredEntries() {
        let cutoff = Date().addingTimeInterval(-entryLifetime)
        entries = entries
            .mapValues { bucket in
                bucket.filter { $0.timestamp >= cutoff }
            }
            .filter { !$0.value.isEmpty }
    }

    private func pruneExpiredProcessDescriptors() {
        let cutoff = Date().addingTimeInterval(-processDescriptorLifetime)
        processDescriptors = processDescriptors.filter { $0.value.timestamp >= cutoff }
    }

    private func dropOldestEntries() {
        var flat: [(key: CacheKey, entry: Entry)] = []
        for (key, bucket) in entries {
            for entry in bucket {
                flat.append((key, entry))
            }
        }
        guard flat.count > maximumEntries else { return }
        flat.sort { $0.entry.timestamp > $1.entry.timestamp }
        let trimmed = Array(flat.prefix(maximumEntries))
        var rebuilt: [CacheKey: [Entry]] = [:]
        for pair in trimmed {
            var bucket = rebuilt[pair.key] ?? []
            bucket.append(pair.entry)
            let limit = maximumEntriesPerKey(for: pair.key)
            if bucket.count > limit {
                bucket = Array(bucket.prefix(limit))
            }
            rebuilt[pair.key] = bucket
        }
        entries = rebuilt
    }

    private func maximumEntriesPerKey(for key: CacheKey) -> Int {
        switch key {
        case .process:
            return maximumEntriesPerProcess
        case .application:
            return maximumEntriesPerApplication
        }
    }

    private func cacheKeys(for pid: pid_t) -> [CacheKey] {
        var keys: [CacheKey] = [.process(pid)]
        if let bundleIdentifier = bundleIdentifier(for: pid) {
            keys.append(.application(bundleIdentifier))
        }
        return keys
    }

    private func bundleIdentifier(for pid: pid_t) -> String? {
        if let cached = processDescriptors[pid] {
            return cached.bundleIdentifier
        }
        let identifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.lowercased()
        processDescriptors[pid] = ProcessDescriptor(bundleIdentifier: identifier, timestamp: Date())
        return identifier
    }

    private func bestMatch(in bucket: [Entry], for frame: NSRect) -> Entry? {
        let signature = Self.signature(for: frame)
        let tightTolerance = max(
            defaultFrameTolerance,
            min(frame.width, frame.height) * 0.06
        )
        let looseTolerance = tightTolerance * 1.8

        if let direct = bucket.first(where: { $0.signature == signature && $0.frame.isApproximatelyEqual(to: frame, tolerance: tightTolerance) }) {
            return direct
        }

        if let fuzzy = bucket.first(where: { $0.frame.isApproximatelyEqual(to: frame, tolerance: looseTolerance) }) {
            return fuzzy
        }

        if let fallback = bucket.first {
            let frameArea = max(frame.width * frame.height, .ulpOfOne)
            let ratio = (fallback.frame.width * fallback.frame.height) / frameArea
            if ratio >= 0.5 && ratio <= 1.8 {
                return fallback
            }
        }

        return nil
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
