import AppKit
import Foundation
import OSLog

/// Captures masking investigations to a shareable log file whenever the hidden unlock code is supplied.
final class InvestigationLogger: @unchecked Sendable {
    static let shared = InvestigationLogger()
    static let unlockCode = "focusly-unmask"
    static let disableCode = "focusly-stop"
    private static let supplementarySignatureHistoryLimit = 200
    private static let suppressedLogSubstrings: [String] = ["alcove"]

    private let loggingQueue = DispatchQueue(label: "com.focusly.app.InvestigationLogger", qos: .utility)
    private var fileURL: URL?
    private let dateFormatter: ISO8601DateFormatter
    private let subsystemLogger = Logger(subsystem: "com.focusly.app", category: "Investigation")
    private var enabled: Bool
    private let environmentOverrideActive: Bool
    private var lastSnapshotSignatureBySource: [String: SnapshotLogSignature] = [:]
    private var supplementarySignatureSet: Set<SupplementaryLogSignature> = []
    private var supplementarySignatureQueue: [SupplementaryLogSignature] = []

    var isEnabled: Bool {
        enabled
    }

    private init() {
        let (initialEnabled, environmentOverride) = InvestigationLogger.initialState()
        self.enabled = initialEnabled
        self.environmentOverrideActive = environmentOverride
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]

        if enabled {
            prepareLogFileIfNeeded(resetHeader: true)
        }
    }

    /// Appends a categorized line to the investigation log when logging is enabled.
    func log(category: String, _ message: String) {
        guard enabled else { return }
        let timestamp = dateFormatter.string(from: Date())
        let composed = "[\(timestamp)][\(category)] \(message)"
        subsystemLogger.log("\(composed, privacy: .public)")
        appendLine(composed, allowWhenDisabled: false)
    }

    /// Blocks until all queued writes complete so callers can safely read the file.
    func flush() {
        loggingQueue.sync { }
    }

    /// Returns the canonical on-disk location used for investigation logs.
    static func logsFileLocation() -> URL {
        resolveLogsDirectory().appendingPathComponent("InvestigationLog.txt")
    }

    /// Toggles logging from the status item action and reports the resulting state.
    func toggleLoggingFromStatusItem() -> (enabled: Bool, location: URL, didChange: Bool) {
        let location = InvestigationLogger.logsFileLocation()
        guard !environmentOverrideActive else {
            subsystemLogger.warning("Investigation logging toggle ignored due to environment override")
            return (enabled, location, false)
        }
        let previous = enabled
        setLoggingEnabled(!enabled, persistPreference: true)
        return (enabled, location, previous != enabled)
    }

    /// Applies a new logging state and optionally persists the corresponding unlock code.
    private func setLoggingEnabled(_ newState: Bool, persistPreference: Bool) {
        guard newState != enabled else { return }
        if persistPreference {
            UserDefaults.standard.set(
                newState ? InvestigationLogger.unlockCode : InvestigationLogger.disableCode,
                forKey: "Focusly.InvestigationCode"
            )
        }

        if newState {
            resetDeduplicationState()
            enabled = true
            prepareLogFileIfNeeded(resetHeader: fileURL == nil)
            log(category: "Control", "Investigation logging enabled")
        } else {
            if let _ = fileURL {
                let timestamp = dateFormatter.string(from: Date())
                let composed = "[\(timestamp)][Control] Investigation logging disabled"
                appendLine(composed, allowWhenDisabled: true)
            }
            enabled = false
            resetDeduplicationState()
        }
    }

    /// Queues a single line append operation, creating the file lazily if needed.
    private func appendLine(_ line: String, allowWhenDisabled: Bool) {
        guard (allowWhenDisabled || enabled), let url = preparedFileURL() else { return }
        loggingQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = (line + "\n").data(using: .utf8) ?? Data()
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: data)
                } else {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    handle.write(data)
                }
            } catch {
                self.subsystemLogger.error("Failed writing investigation log: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Ensures a writable file URL exists before writes are attempted.
    private func preparedFileURL() -> URL? {
        if let url = fileURL {
            return url
        }
        prepareLogFileIfNeeded(resetHeader: true)
        return fileURL
    }

    /// Creates the log directory/file and optionally rewrites the file header.
    private func prepareLogFileIfNeeded(resetHeader: Bool) {
        let logsDirectory = InvestigationLogger.resolveLogsDirectory()
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let targetURL = logsDirectory.appendingPathComponent("InvestigationLog.txt")
        fileURL = targetURL
        if resetHeader {
            writeHeader(to: targetURL)
        }
    }

    /// Writes the standard investigation header with enable/disable instructions.
    private func writeHeader(to url: URL) {
        let directory = url.deletingLastPathComponent()
        let header = """
        ---- Focusly Investigation Log (\(dateFormatter.string(from: Date()))) ----
        To enable logging: defaults write com.focusly.app Focusly.InvestigationCode -string \(InvestigationLogger.unlockCode)
        To disable logging: defaults write com.focusly.app Focusly.InvestigationCode -string \(InvestigationLogger.disableCode)
        Log directory: \(directory.path)

        """
        loggingQueue.async {
            try? header.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Clears deduplication caches so repeated snapshots can be logged again.
    private func resetDeduplicationState() {
        loggingQueue.sync {
            lastSnapshotSignatureBySource.removeAll(keepingCapacity: false)
            supplementarySignatureSet.removeAll(keepingCapacity: false)
            supplementarySignatureQueue.removeAll(keepingCapacity: false)
        }
    }

    /// Resolves initial logging state from environment overrides and persisted defaults.
    private static func initialState() -> (Bool, Bool) {
        let environment = ProcessInfo.processInfo.environment
        if let envCode = environment["FOCUSLY_INVESTIGATION_CODE"] {
            if envCode == InvestigationLogger.disableCode {
                return (false, true)
            }
            if envCode == InvestigationLogger.unlockCode {
                return (true, true)
            }
        }
        let defaultsCode = UserDefaults.standard.string(forKey: "Focusly.InvestigationCode")
        if defaultsCode == InvestigationLogger.disableCode {
            return (false, false)
        }
        if defaultsCode == InvestigationLogger.unlockCode {
            return (true, false)
        }
        return (false, false)
    }

    /// Computes the app-specific log directory under the user's Library/Logs folder.
    private static func resolveLogsDirectory() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        return (base ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("Logs/Focusly", isDirectory: true)
    }
}

extension InvestigationLogger {
    /// Logs a focused-window snapshot while deduplicating unchanged entries per source.
    func logSnapshot(source: String, frame: NSRect, cornerRadius: CGFloat, supplementaryCount: Int) {
        guard shouldLogSnapshot(source: source, frame: frame, cornerRadius: cornerRadius, supplementaryCount: supplementaryCount) else {
            return
        }
        let rectDescription = String(
            format: "x:%.1f y:%.1f w:%.1f h:%.1f",
            frame.origin.x, frame.origin.y, frame.width, frame.height
        )
        log(
            category: "Snapshot",
            "\(source) frame=\(rectDescription) cornerRadius=\(String(format: "%.2f", cornerRadius)) supplementary=\(supplementaryCount)"
        )
    }

    /// Logs ignore-list decisions for windows excluded from masking.
    func logIgnoredWindow(ownerName: String?, windowName: String?, reason: String) {
        guard !shouldSuppressLog(ownerName: ownerName, windowName: windowName) else { return }
        log(
            category: "IgnoreList",
            "reason=\(reason) owner=\(ownerName ?? "(unknown)") title=\(windowName ?? "(untitled)")"
        )
    }

    /// Logs why a supplementary candidate was skipped during classification.
    func logSupplementarySkip(ownerName: String?, windowName: String?, layerIndex: Int, bounds: CGRect, reason: String) {
        guard !shouldSuppressLog(ownerName: ownerName, windowName: windowName) else { return }
        let rectDescription = String(
            format: "x:%.1f y:%.1f w:%.1f h:%.1f",
            bounds.origin.x, bounds.origin.y, bounds.width, bounds.height
        )
        log(
            category: "Supplementary",
            "Skipped (\(reason)) owner=\(ownerName ?? "(unknown)") title=\(windowName ?? "(untitled)") layer=\(layerIndex) frame=\(rectDescription)"
        )
    }

    /// Logs the resolved classification for a supplementary mask region.
    func logSupplementaryClassification(
        ownerName: String?,
        windowName: String?,
        layerIndex: Int,
        bounds: CGRect,
        purpose: ActiveWindowSnapshot.MaskRegion.Purpose
    ) {
        guard shouldLogSupplementaryClassification(
            ownerName: ownerName,
            windowName: windowName,
            layerIndex: layerIndex,
            bounds: bounds,
            purpose: purpose
        ) else { return }
        let rectDescription = String(
            format: "x:%.1f y:%.1f w:%.1f h:%.1f",
            bounds.origin.x, bounds.origin.y, bounds.width, bounds.height
        )
        let classification: String
        switch purpose {
        case .applicationWindow:
            classification = "applicationWindow"
        case .applicationMenu:
            classification = "applicationMenu"
        case .systemMenu:
            classification = "systemMenu"
        }
        log(
            category: "Supplementary",
            "Classified owner=\(ownerName ?? "(unknown)") title=\(windowName ?? "(untitled)") layer=\(layerIndex) frame=\(rectDescription) classification=\(classification)"
        )
    }

    /// Logs a raw supplementary candidate before classification is finalized.
    func logSupplementaryCandidate(
        ownerName: String?,
        windowName: String?,
        layerIndex: Int,
        bounds: CGRect,
        matchesPrimary: Bool
    ) {
        guard !shouldSuppressLog(ownerName: ownerName, windowName: windowName) else { return }
        let rectDescription = String(
            format: "x:%.1f y:%.1f w:%.1f h:%.1f",
            bounds.origin.x, bounds.origin.y, bounds.width, bounds.height
        )
        log(
            category: "Supplementary",
            "Candidate owner=\(ownerName ?? "(unknown)") title=\(windowName ?? "(untitled)") layer=\(layerIndex) frame=\(rectDescription) matchesPrimary=\(matchesPrimary)"
        )
    }

    /// Logs discovery of a supplementary window dictionary from CoreGraphics.
    func logSupplementaryDiscovery(
        ownerName: String?,
        windowName: String?,
        layerIndex: Int,
        bounds: CGRect
    ) {
        guard !shouldSuppressLog(ownerName: ownerName, windowName: windowName) else { return }
        let rectDescription = String(
            format: "x:%.1f y:%.1f w:%.1f h:%.1f",
            bounds.origin.x, bounds.origin.y, bounds.width, bounds.height
        )
        log(
            category: "Supplementary",
            "Discovered owner=\(ownerName ?? "(unknown)") title=\(windowName ?? "(untitled)") layer=\(layerIndex) frame=\(rectDescription)"
        )
    }
}

private extension InvestigationLogger {
    struct SnapshotLogSignature: Equatable {
        let rectSignature: RectSignature
        let cornerRadius: Int
        let supplementaryCount: Int

        init(frame: NSRect, cornerRadius: CGFloat, supplementaryCount: Int) {
            self.rectSignature = RectSignature(rect: CGRect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height))
            self.cornerRadius = investigationQuantize(cornerRadius)
            self.supplementaryCount = supplementaryCount
        }
    }

    struct SupplementaryLogSignature: Hashable {
        let ownerKey: String
        let windowKey: String
        let layerIndex: Int
        let rectSignature: RectSignature
        let purposeKey: Int

        init(
            ownerName: String?,
            windowName: String?,
            layerIndex: Int,
            rectSignature: RectSignature,
            purpose: ActiveWindowSnapshot.MaskRegion.Purpose
        ) {
            self.ownerKey = ownerName?.lowercased() ?? ""
            self.windowKey = windowName?.lowercased() ?? ""
            self.layerIndex = layerIndex
            self.rectSignature = rectSignature
            self.purposeKey = SupplementaryLogSignature.purposeKey(for: purpose)
        }

        /// Maps supplementary mask purpose values to compact deduplication keys.
        private static func purposeKey(for purpose: ActiveWindowSnapshot.MaskRegion.Purpose) -> Int {
            switch purpose {
            case .applicationWindow: return 0
            case .applicationMenu: return 1
            case .systemMenu: return 2
            }
        }
    }

    struct RectSignature: Hashable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        init(rect: CGRect) {
            self.x = investigationQuantize(rect.origin.x)
            self.y = investigationQuantize(rect.origin.y)
            self.width = investigationQuantize(rect.size.width)
            self.height = investigationQuantize(rect.size.height)
        }
    }

    /// Deduplicates repeated snapshot entries per source so logs remain readable.
    func shouldLogSnapshot(source: String, frame: NSRect, cornerRadius: CGFloat, supplementaryCount: Int) -> Bool {
        let signature = SnapshotLogSignature(frame: frame, cornerRadius: cornerRadius, supplementaryCount: supplementaryCount)
        if let previous = lastSnapshotSignatureBySource[source], previous == signature {
            return false
        }
        lastSnapshotSignatureBySource[source] = signature
        return true
    }

    /// Suppresses noisy log entries matching known low-signal owner/title fragments.
    func shouldSuppressLog(ownerName: String?, windowName: String?) -> Bool {
        let owner = ownerName?.lowercased() ?? ""
        let window = windowName?.lowercased() ?? ""
        if owner.isEmpty, window.isEmpty {
            return false
        }
        return Self.suppressedLogSubstrings.contains {
            (!owner.isEmpty && owner.contains($0)) || (!window.isEmpty && window.contains($0))
        }
    }

    /// Checks whether a supplementary classification event is new enough to emit.
    func shouldLogSupplementaryClassification(
        ownerName: String?,
        windowName: String?,
        layerIndex: Int,
        bounds: CGRect,
        purpose: ActiveWindowSnapshot.MaskRegion.Purpose
    ) -> Bool {
        if shouldSuppressLog(ownerName: ownerName, windowName: windowName) {
            return false
        }
        let signature = SupplementaryLogSignature(
            ownerName: ownerName,
            windowName: windowName,
            layerIndex: layerIndex,
            rectSignature: RectSignature(rect: bounds),
            purpose: purpose
        )
        return registerSupplementarySignature(signature)
    }

    /// Maintains a bounded history set for emitted supplementary signatures.
    func registerSupplementarySignature(_ signature: SupplementaryLogSignature) -> Bool {
        if supplementarySignatureSet.contains(signature) {
            return false
        }
        supplementarySignatureSet.insert(signature)
        supplementarySignatureQueue.append(signature)
        if supplementarySignatureQueue.count > Self.supplementarySignatureHistoryLimit {
            let removed = supplementarySignatureQueue.removeFirst()
            supplementarySignatureSet.remove(removed)
        }
        return true
    }
}

/// Quantizes geometry values to one decimal place for stable deduplication keys.
private func investigationQuantize(_ value: CGFloat) -> Int {
    Int((value * 10).rounded())
}
