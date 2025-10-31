import AppKit
import Combine

/// View model powering the SwiftUI preferences scene with strongly typed callbacks into the app.
@MainActor
final class PreferencesViewModel: ObservableObject {
    /// Editable overlay configuration for a single display.
    struct DisplaySettings: Identifiable {
        let id: DisplayID
        var name: String
        var opacity: Double
        var tint: NSColor
        var colorTreatment: FocusOverlayColorTreatment
        var blurRadius: Double
        var isExcluded: Bool

        var tintPreview: NSColor {
            tint
        }
    }

    /// Glue closures that let the preferences UI trigger app-level changes.
    struct Callbacks {
        /// Glue closure bundle so the view model can stay UI focused without knowing about app coordination.
        var onDisplayChange: (DisplayID, FocusOverlayStyle) -> Void
        var onDisplayReset: (DisplayID) -> Void
        var onRequestShortcutCapture: (@escaping (HotkeyShortcut?) -> Void) -> Void
        var onUpdateShortcut: (HotkeyShortcut?) -> Void
        var onToggleHotkeys: (Bool) -> Void
        var onToggleLaunchAtLogin: (Bool) -> Void
        var onRequestOnboarding: () -> Void
        var onUpdateStatusIconStyle: (StatusBarIconStyle) -> Void
        var onSelectPreset: (FocusPreset) -> Void
        var onSelectLanguage: (String) -> Void
        var onUpdateTrackingProfile: (WindowTrackingProfile) -> Void
        var onToggleDisplayExclusion: (DisplayID, Bool) -> Void
    }

    @Published var displaySettings: [DisplaySettings]
    @Published var presetOptions: [FocusPreset]
    @Published var selectedPresetIdentifier: String
    @Published var hotkeysEnabled: Bool
    @Published var isLaunchAtLoginEnabled: Bool
    @Published var isLaunchAtLoginAvailable: Bool
    @Published var launchAtLoginStatusMessage: String?
    @Published var isCapturingShortcut = false
    @Published private(set) var shortcutSummary: String
    @Published var statusIconStyle: StatusBarIconStyle
    @Published var trackingProfile: WindowTrackingProfile
    private var activeShortcut: HotkeyShortcut?
    /// App coordination closures invoked when preferences mutate shared state.
    private let callbacks: Callbacks
    let iconStyleOptions: [StatusBarIconStyle]
    let trackingProfileOptions: [WindowTrackingProfile]

    /// Creates the view model with the current overlay, shortcut, and status bar state.
    init(
        displaySettings: [DisplaySettings],
        hotkeysEnabled: Bool,
        isLaunchAtLoginEnabled: Bool,
        isLaunchAtLoginAvailable: Bool,
        launchAtLoginStatusMessage: String?,
        activeShortcut: HotkeyShortcut?,
        statusIconStyle: StatusBarIconStyle,
        iconStyleOptions: [StatusBarIconStyle],
        presetOptions: [FocusPreset],
        selectedPresetIdentifier: String,
        trackingProfile: WindowTrackingProfile,
        trackingProfileOptions: [WindowTrackingProfile],
        callbacks: Callbacks
    ) {
        self.displaySettings = displaySettings
        self.presetOptions = presetOptions
        self.selectedPresetIdentifier = selectedPresetIdentifier
        self.hotkeysEnabled = hotkeysEnabled
        self.isLaunchAtLoginEnabled = isLaunchAtLoginEnabled
        self.isLaunchAtLoginAvailable = isLaunchAtLoginAvailable
        self.launchAtLoginStatusMessage = launchAtLoginStatusMessage
        self.activeShortcut = activeShortcut
        self.callbacks = callbacks
        self.shortcutSummary = PreferencesViewModel.describeShortcut(activeShortcut)
        self.statusIconStyle = statusIconStyle
        self.iconStyleOptions = iconStyleOptions
        self.trackingProfile = trackingProfile
        self.trackingProfileOptions = trackingProfileOptions
    }

    /// Persists live opacity changes for a display and notifies the app.
    func updateOpacity(for displayID: DisplayID, value updatedOpacity: Double) {
        guard let settingsIndex = displaySettings.firstIndex(where: { $0.id == displayID }) else { return }
        displaySettings[settingsIndex].opacity = updatedOpacity
        commit(displaySettings: displaySettings[settingsIndex])
    }

    /// Persists tint adjustments for a display and notifies the app.
    func updateTint(for displayID: DisplayID, value updatedTint: NSColor) {
        guard let settingsIndex = displaySettings.firstIndex(where: { $0.id == displayID }) else { return }
        displaySettings[settingsIndex].tint = updatedTint
        commit(displaySettings: displaySettings[settingsIndex])
    }

    /// Persists blur radius adjustments for a display and notifies the app.
    func updateBlur(for displayID: DisplayID, radius: Double) {
        guard let settingsIndex = displaySettings.firstIndex(where: { $0.id == displayID }) else { return }
        displaySettings[settingsIndex].blurRadius = max(0, radius)
        commit(displaySettings: displaySettings[settingsIndex])
    }

    /// Persists color treatment changes for a display and notifies the app.
    func updateColorTreatment(for displayID: DisplayID, treatment: FocusOverlayColorTreatment) {
        guard let settingsIndex = displaySettings.firstIndex(where: { $0.id == displayID }) else { return }
        displaySettings[settingsIndex].colorTreatment = treatment
        commit(displaySettings: displaySettings[settingsIndex])
    }

    /// Reverts a display to its preset defaults.
    func resetDisplay(_ displayID: DisplayID) {
        callbacks.onDisplayReset(displayID)
    }

    /// Marks a display as excluded so overlays skip rendering on it.
    func setDisplayExcluded(_ displayID: DisplayID, excluded: Bool) {
        guard let settingsIndex = displaySettings.firstIndex(where: { $0.id == displayID }) else { return }
        displaySettings[settingsIndex].isExcluded = excluded
        callbacks.onToggleDisplayExclusion(displayID, excluded)
    }

    /// Switches to a new preset and informs the coordinator.
    func selectPreset(id: String) {
        guard selectedPresetIdentifier != id else { return }
        selectedPresetIdentifier = id
        guard let preset = preset(for: id) else { return }
        callbacks.onSelectPreset(preset)
    }

    /// Copies one display's settings across all others.
    func syncDisplaySettings(from displayID: DisplayID) {
        guard let sourceDisplaySettings = displaySettings.first(where: { $0.id == displayID }) else { return }
        for settingsIndex in displaySettings.indices where displaySettings[settingsIndex].id != displayID {
            displaySettings[settingsIndex].opacity = sourceDisplaySettings.opacity
            displaySettings[settingsIndex].tint = sourceDisplaySettings.tint
            displaySettings[settingsIndex].colorTreatment = sourceDisplaySettings.colorTreatment
            displaySettings[settingsIndex].blurRadius = sourceDisplaySettings.blurRadius
            commit(displaySettings: displaySettings[settingsIndex])
        }
    }

    /// Enables or disables the global hotkey preference.
    func setHotkeysEnabled(_ enabled: Bool) {
        hotkeysEnabled = enabled
        callbacks.onToggleHotkeys(enabled)
    }

    /// Toggles the launch-at-login setting when the feature is supported.
    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard isLaunchAtLoginAvailable else { return }
        isLaunchAtLoginEnabled = enabled
        callbacks.onToggleLaunchAtLogin(enabled)
    }

    /// Initiates capturing a new shortcut and updates state when recording finishes.
    func beginShortcutCapture() {
        isCapturingShortcut = true
        callbacks.onRequestShortcutCapture { [weak self] shortcut in
            guard let self else { return }
            self.isCapturingShortcut = false
            self.activeShortcut = shortcut
            self.shortcutSummary = PreferencesViewModel.describeShortcut(shortcut)
            self.callbacks.onUpdateShortcut(shortcut)
        }
    }

    /// Removes the current shortcut so no global hotkey remains registered.
    func clearShortcut() {
        activeShortcut = nil
        shortcutSummary = "—"
        callbacks.onUpdateShortcut(nil)
    }

    /// Persists the status bar icon style choice.
    func updateStatusIconStyle(_ style: StatusBarIconStyle) {
        statusIconStyle = style
        callbacks.onUpdateStatusIconStyle(style)
    }

    /// Applies the selected window tracking performance profile.
    func updateTrackingProfile(_ profile: WindowTrackingProfile) {
        guard trackingProfile != profile else { return }
        trackingProfile = profile
        callbacks.onUpdateTrackingProfile(profile)
    }

    /// Passes the newly selected localization identifier back to the coordinator.
    func setLanguage(id: String) {
        callbacks.onSelectLanguage(id)
    }

    /// Requests that the onboarding sequence be shown again.
    func showOnboarding() {
        callbacks.onRequestOnboarding()
    }

    /// Applies a shortcut received from outside the view model (e.g., persisted state).
    func applyShortcut(_ activeShortcut: HotkeyShortcut?) {
        self.activeShortcut = activeShortcut
        shortcutSummary = PreferencesViewModel.describeShortcut(activeShortcut)
    }

    /// Converts UI-managed display settings into a `FocusOverlayStyle` and emits callbacks.
    private func commit(displaySettings: DisplaySettings) {
        let normalizedTintColor = displaySettings.tint.usingColorSpace(.genericRGB) ?? displaySettings.tint
        let focusTint = FocusTint(
            red: Double(normalizedTintColor.redComponent),
            green: Double(normalizedTintColor.greenComponent),
            blue: Double(normalizedTintColor.blueComponent),
            alpha: Double(normalizedTintColor.alphaComponent)
        )
        let overlayStyle = FocusOverlayStyle(
            opacity: displaySettings.opacity,
            tint: focusTint,
            animationDuration: 0.3,
            colorTreatment: displaySettings.colorTreatment,
            blurRadius: displaySettings.blurRadius
        )
        callbacks.onDisplayChange(displaySettings.id, overlayStyle)
    }

    /// Builds a human-readable representation of a shortcut for UI display.
    private static func describeShortcut(_ activeShortcut: HotkeyShortcut?) -> String {
        guard let activeShortcut else { return "—" }
        var components: [String] = []
        let flags = activeShortcut.modifiers
        if flags.contains(.control) { components.append("⌃") }
        if flags.contains(.option) { components.append("⌥") }
        if flags.contains(.shift) { components.append("⇧") }
        if flags.contains(.command) { components.append("⌘") }
        if let key = KeyTransformer.displayName(for: activeShortcut.keyCode) {
            components.append(key)
        } else {
            components.append(String(format: "%02X", activeShortcut.keyCode))
        }
        return components.joined(separator: " ")
    }

    /// Finds the matching preset for the supplied identifier, updating selection if necessary.
    private func preset(for id: String) -> FocusPreset? {
        if let match = presetOptions.first(where: { $0.id == id }) {
            return match
        }
        if let fallback = presetOptions.first {
            selectedPresetIdentifier = fallback.id
            return fallback
        }
        return nil
    }
}

/// Minimal key code to character mapper for displaying shortcuts.
private enum KeyTransformer {
    /// Human-friendly glyph or label for a given hardware key code.
    static func displayName(for keyCode: UInt32) -> String? {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 11: return "B"
        case 15: return "R"
        case 35: return "P"
        case 49:
            return NSLocalizedString(
                "Space",
                tableName: nil,
                bundle: .module,
                value: "Space",
                comment: "Display name for the space bar in shortcuts."
            )
        default: return nil
        }
    }
}
