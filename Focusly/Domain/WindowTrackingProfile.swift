import Foundation

/// User-facing performance profiles that control how frequently Focusly samples window positions.
enum WindowTrackingProfile: String, CaseIterable, Identifiable {
    case energySaving
    case standard
    case highPerformance

    var id: String { rawValue }

    /// Baseline polling interval (seconds per sample).
    var idleInterval: TimeInterval {
        switch self {
        case .energySaving:
            return 1.0 / 30.0
        case .standard:
            return 1.0 / 60.0
        case .highPerformance:
            return 1.0 / 90.0
        }
    }

    /// Polling interval used when pointer interactions are active.
    var interactionInterval: TimeInterval {
        idleInterval
    }

    /// Slower cadence used once overlays have been idle for a while.
    var quiescentInterval: TimeInterval {
        switch self {
        case .energySaving:
            return 2.2
        case .standard:
            return 1.35
        case .highPerformance:
            return 0.95
        }
    }

    /// How long Focusly should wait (in seconds) before falling back to the quiescent cadence.
    var quiescentEntryDelay: TimeInterval {
        switch self {
        case .energySaving:
            return 0.6
        case .standard:
            return 0.85
        case .highPerformance:
            return 1.1
        }
    }

    /// Human-readable refresh rate.
    var hertzDisplayValue: Int {
        switch self {
        case .energySaving:
            return 30
        case .standard:
            return 60
        case .highPerformance:
            return 90
        }
    }

    /// Localization key for the option title.
    var titleLocalizationKey: String {
        switch self {
        case .energySaving:
            return "WindowTrackingProfile.EnergySaving.Title"
        case .standard:
            return "WindowTrackingProfile.Standard.Title"
        case .highPerformance:
            return "WindowTrackingProfile.HighPerformance.Title"
        }
    }

    /// Fallback title used when no translation exists.
    var titleFallback: String {
        switch self {
        case .energySaving:
            return "Energy Saving (30 Hz)"
        case .standard:
            return "Standard (60 Hz)"
        case .highPerformance:
            return "High Performance (90 Hz)"
        }
    }

    /// Localization key for the explanatory blurb.
    var descriptionLocalizationKey: String {
        switch self {
        case .energySaving:
            return "WindowTrackingProfile.EnergySaving.Description"
        case .standard:
            return "WindowTrackingProfile.Standard.Description"
        case .highPerformance:
            return "WindowTrackingProfile.HighPerformance.Description"
        }
    }

    /// Fallback explanatory text for the option.
    var descriptionFallback: String {
        switch self {
        case .energySaving:
            return "Updates dragged windows 30 times per second to conserve energy."
        case .standard:
            return "Keeps overlays in sync at 60 Hz while you move windows."
        case .highPerformance:
            return "Follows window movement at 90 Hz for the smoothest tracking."
        }
    }
}
