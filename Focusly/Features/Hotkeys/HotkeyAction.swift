import Foundation

/// Represents the global actions Focusly can bind to keyboard shortcuts.
enum HotkeyAction: Int, CaseIterable, Identifiable {
    case overlayToggle = 1
    case maskingModeToggle = 2

    var id: Int { rawValue }

    /// Localized key used for settings titles.
    var preferenceTitleKey: String {
        switch self {
        case .overlayToggle:
            return "HotkeyOverlayToggleTitle"
        case .maskingModeToggle:
            return "HotkeyMaskingToggleTitle"
        }
    }

    /// Fallback copy when a localized string is unavailable.
    var preferenceTitleFallback: String {
        switch self {
        case .overlayToggle:
            return "Toggle Focusly overlays"
        case .maskingModeToggle:
            return "Switch masking mode per display"
        }
    }

    /// Secondary description shown under the toggle in Preferences.
    var preferenceDescriptionKey: String {
        switch self {
        case .overlayToggle:
            return "HotkeyOverlayToggleDescription"
        case .maskingModeToggle:
            return "HotkeyMaskingToggleDescription"
        }
    }

    /// Fallback description copy used when localization is missing.
    var preferenceDescriptionFallback: String {
        switch self {
        case .overlayToggle:
            return "Show or hide the blur/tint overlays without touching the menu bar."
        case .maskingModeToggle:
            return "Cycle between highlighting only the focused window or every window of the foreground app."
        }
    }
}
