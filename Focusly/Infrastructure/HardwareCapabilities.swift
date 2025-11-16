import Foundation
import Darwin

/// Centralized view of the host hardware capabilities so high-performance code paths
/// can be selectively enabled on machines that can handle the extra work.
enum HardwareCapabilities {
    /// Lazily resolved `hw.model` string (e.g. "Mac14,7").
    private static let machineIdentifier: String? = {
        var size: size_t = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let trimmedBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard !trimmedBytes.isEmpty else { return nil }
        return String(decoding: trimmedBytes, as: UTF8.self)
    }()

    /// Returns true when running on any Apple Silicon Mac.
    static let isAppleSilicon: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    /// Returns true for second-generation Apple Silicon (M2-era) identifiers.
    static let isSecondGenerationAppleSilicon: Bool = {
        guard isAppleSilicon, let identifier = machineIdentifier else { return false }
        let supportedPrefixes = ["Mac14"]
        return supportedPrefixes.contains { identifier.hasPrefix($0) }
    }()

    /// Returns true for third-generation Apple Silicon (M3 and newer) identifiers.
    static let isThirdGenerationAppleSilicon: Bool = {
        guard isAppleSilicon, let identifier = machineIdentifier else { return false }
        let supportedPrefixes = ["Mac15", "Mac16", "Mac17", "Mac18", "Mac19", "Mac20"]
        return supportedPrefixes.contains { identifier.hasPrefix($0) }
    }()

    /// Whether the host GPU can comfortably run high-refresh compositing paths.
    static let supportsHighRefreshCompositing: Bool = {
        guard isAppleSilicon else { return false }
        if isThirdGenerationAppleSilicon { return true }
        if isSecondGenerationAppleSilicon { return true }
        return false
    }()

    /// Whether the host GPU/CPU pairing can sustain the pointer-driven sampling path for smoother drags.
    static let supportsPointerDrivenInteractionBoosts: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()
}
