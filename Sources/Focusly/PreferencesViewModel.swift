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
    }

    @Published var displaySettings: [DisplaySettings]
    @Published var presetOptions: [FocusPreset]
    @Published var selectedPresetIdentifier: String
    @Published var areHotkeysEnabled: Bool
    @Published var isLaunchAtLoginEnabled: Bool
    @Published var isLaunchAtLoginAvailable: Bool
    @Published var launchAtLoginStatusMessage: String?
    @Published var isCapturingShortcut = false
    @Published private(set) var shortcutSummary: String
    @Published var statusIconStyle: StatusBarIconStyle
    private var activeShortcut: HotkeyShortcut?
    private let handlers: Callbacks
    let iconStyleOptions: [StatusBarIconStyle]

    /// Creates the view model with the current overlay, shortcut, and status bar state.
    init(
        displaySettings: [DisplaySettings],
        areHotkeysEnabled: Bool,
        isLaunchAtLoginEnabled: Bool,
        isLaunchAtLoginAvailable: Bool,
        launchAtLoginStatusMessage: String?,
        activeShortcut: HotkeyShortcut?,
        statusIconStyle: StatusBarIconStyle,
        iconStyleOptions: [StatusBarIconStyle],
        presetOptions: [FocusPreset],
        selectedPresetIdentifier: String,
        handlers: Callbacks
    ) {
        self.displaySettings = displaySettings
        self.presetOptions = presetOptions
        self.selectedPresetIdentifier = selectedPresetIdentifier
        self.areHotkeysEnabled = areHotkeysEnabled
        self.isLaunchAtLoginEnabled = isLaunchAtLoginEnabled
        self.isLaunchAtLoginAvailable = isLaunchAtLoginAvailable
        self.launchAtLoginStatusMessage = launchAtLoginStatusMessage
        self.activeShortcut = activeShortcut
        self.handlers = handlers
        self.shortcutSummary = PreferencesViewModel.describeShortcut(activeShortcut)
        self.statusIconStyle = statusIconStyle
        self.iconStyleOptions = iconStyleOptions
    }

    /// Persists live opacity changes for a display and notifies the app.
    func updateOpacity(for displayID: DisplayID, value: Double) {
        guard let index = displaySettings.firstIndex(where: { $0.id == displayID }) else { return }
        displaySettings[index].opacity = value
        commit(display: displaySettings[index])
    }

    /// Persists tint adjustments for a display and notifies the app.
    func updateTint(for displayID: DisplayID, value: NSColor) {
        guard let index = displaySettings.firstIndex(where: { $0.id == displayID }) else { return }
        displaySettings[index].tint = value
        commit(display: displaySettings[index])
    }

    /// Reverts a display to its preset defaults.
    func resetDisplay(_ displayID: DisplayID) {
        handlers.onDisplayReset(displayID)
    }

    /// Switches to a new preset and informs the coordinator.
    func selectPreset(id: String) {
        guard selectedPresetIdentifier != id else { return }
        selectedPresetIdentifier = id
        guard let preset = preset(for: id) else { return }
        handlers.onSelectPreset(preset)
    }

    /// Copies one display's settings across all others.
    func syncDisplaySettings(from displayID: DisplayID) {
        guard let source = displaySettings.first(where: { $0.id == displayID }) else { return }
        for index in displaySettings.indices where displaySettings[index].id != displayID {
            displaySettings[index].opacity = source.opacity
            displaySettings[index].tint = source.tint
            displaySettings[index].colorTreatment = source.colorTreatment
            commit(display: displaySettings[index])
        }
    }

    /// Enables or disables the global hotkey preference.
    func setHotkeysEnabled(_ enabled: Bool) {
        areHotkeysEnabled = enabled
        handlers.onToggleHotkeys(enabled)
    }

    /// Toggles the launch-at-login setting when the feature is supported.
    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard isLaunchAtLoginAvailable else { return }
        isLaunchAtLoginEnabled = enabled
        handlers.onToggleLaunchAtLogin(enabled)
    }

    /// Initiates capturing a new shortcut and updates state when recording finishes.
    func beginShortcutCapture() {
        isCapturingShortcut = true
        handlers.onRequestShortcutCapture { [weak self] shortcut in
            guard let self else { return }
            self.isCapturingShortcut = false
            self.activeShortcut = shortcut
            self.shortcutSummary = PreferencesViewModel.describeShortcut(shortcut)
            self.handlers.onUpdateShortcut(shortcut)
        }
    }

    /// Removes the current shortcut so no global hotkey remains registered.
    func clearShortcut() {
        activeShortcut = nil
        shortcutSummary = "—"
        handlers.onUpdateShortcut(nil)
    }

    /// Persists the status bar icon style choice.
    func updateStatusIconStyle(_ style: StatusBarIconStyle) {
        statusIconStyle = style
        handlers.onUpdateStatusIconStyle(style)
    }

    /// Passes the newly selected localization identifier back to the coordinator.
    func setLanguage(id: String) {
        handlers.onSelectLanguage(id)
    }

    /// Requests that the onboarding sequence be shown again.
    func showOnboarding() {
        handlers.onRequestOnboarding()
    }

    /// Applies a shortcut received from outside the view model (e.g., persisted state).
    func applyShortcut(_ activeShortcut: HotkeyShortcut?) {
        self.activeShortcut = activeShortcut
        shortcutSummary = PreferencesViewModel.describeShortcut(activeShortcut)
    }

    /// Converts UI-managed display settings into a `FocusOverlayStyle` and emits callbacks.
    private func commit(display: DisplaySettings) {
        let baseColor = display.tint.usingColorSpace(.genericRGB) ?? display.tint
        let tint = FocusTint(
            red: Double(baseColor.redComponent),
            green: Double(baseColor.greenComponent),
            blue: Double(baseColor.blueComponent),
            alpha: Double(baseColor.alphaComponent)
        )
        let style = FocusOverlayStyle(
            opacity: display.opacity,
            tint: tint,
            animationDuration: 0.3,
            colorTreatment: display.colorTreatment
        )
        handlers.onDisplayChange(display.id, style)
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
