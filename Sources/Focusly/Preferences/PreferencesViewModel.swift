import AppKit
import Combine

@MainActor
final class PreferencesViewModel: ObservableObject {
    struct DisplaySettings: Identifiable {
        let id: DisplayID
        var name: String
        var opacity: Double
        var blurRadius: Double
        var tint: NSColor

        var tintPreview: NSColor {
            tint
        }
    }

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
    }

    @Published var displays: [DisplaySettings]
    @Published var availablePresets: [FocusPreset]
    @Published var selectedPresetID: String
    @Published var hotkeysEnabled: Bool
    @Published var launchAtLoginEnabled: Bool
    @Published var launchAtLoginAvailable: Bool
    @Published var launchAtLoginMessage: String?
    @Published var capturingShortcut = false
    @Published private(set) var shortcutDescription: String
    @Published var statusIconStyle: StatusBarIconStyle

    private var shortcut: HotkeyShortcut?
    private let callbacks: Callbacks
    let availableIconStyles: [StatusBarIconStyle]

    init(
        displays: [DisplaySettings],
        hotkeysEnabled: Bool,
        launchAtLoginEnabled: Bool,
        launchAtLoginAvailable: Bool,
        launchAtLoginMessage: String?,
        shortcut: HotkeyShortcut?,
        statusIconStyle: StatusBarIconStyle,
        availableIconStyles: [StatusBarIconStyle],
        availablePresets: [FocusPreset],
        selectedPresetID: String,
        callbacks: Callbacks
    ) {
        self.displays = displays
        self.availablePresets = availablePresets
        self.selectedPresetID = selectedPresetID
        self.hotkeysEnabled = hotkeysEnabled
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.launchAtLoginAvailable = launchAtLoginAvailable
        self.launchAtLoginMessage = launchAtLoginMessage
        self.shortcut = shortcut
        self.callbacks = callbacks
        self.shortcutDescription = PreferencesViewModel.describeShortcut(shortcut)
        self.statusIconStyle = statusIconStyle
        self.availableIconStyles = availableIconStyles
    }

    func updateOpacity(for displayID: DisplayID, value: Double) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displays[index].opacity = value
        commit(display: displays[index])
    }

    func updateBlur(for displayID: DisplayID, value: Double) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displays[index].blurRadius = value
        commit(display: displays[index])
    }

    func updateTint(for displayID: DisplayID, value: NSColor) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        displays[index].tint = value
        commit(display: displays[index])
    }

    func resetDisplay(_ displayID: DisplayID) {
        callbacks.onDisplayReset(displayID)
    }

    func selectPreset(id: String) {
        guard selectedPresetID != id else { return }
        selectedPresetID = id
        guard let preset = preset(for: id) else { return }
        callbacks.onSelectPreset(preset)
    }

    func syncDisplaySettings(from displayID: DisplayID) {
        guard let source = displays.first(where: { $0.id == displayID }) else { return }
        for index in displays.indices where displays[index].id != displayID {
            displays[index].opacity = source.opacity
            displays[index].blurRadius = source.blurRadius
            displays[index].tint = source.tint
            commit(display: displays[index])
        }
    }

    func setHotkeysEnabled(_ enabled: Bool) {
        hotkeysEnabled = enabled
        callbacks.onToggleHotkeys(enabled)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard launchAtLoginAvailable else { return }
        launchAtLoginEnabled = enabled
        callbacks.onToggleLaunchAtLogin(enabled)
    }

    func beginShortcutCapture() {
        capturingShortcut = true
        callbacks.onRequestShortcutCapture { [weak self] shortcut in
            guard let self else { return }
            self.capturingShortcut = false
            self.shortcut = shortcut
            self.shortcutDescription = PreferencesViewModel.describeShortcut(shortcut)
            self.callbacks.onUpdateShortcut(shortcut)
        }
    }

    func clearShortcut() {
        shortcut = nil
        shortcutDescription = "—"
        callbacks.onUpdateShortcut(nil)
    }

    func updateStatusIconStyle(_ style: StatusBarIconStyle) {
        statusIconStyle = style
        callbacks.onUpdateStatusIconStyle(style)
    }

    func showOnboarding() {
        callbacks.onRequestOnboarding()
    }

    func applyShortcut(_ shortcut: HotkeyShortcut?) {
        self.shortcut = shortcut
        shortcutDescription = PreferencesViewModel.describeShortcut(shortcut)
    }

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
            blurRadius: display.blurRadius,
            tint: tint,
            animationDuration: 0.3
        )
        callbacks.onDisplayChange(display.id, style)
    }

    private static func describeShortcut(_ shortcut: HotkeyShortcut?) -> String {
        guard let shortcut else { return "—" }
        var components: [String] = []
        let flags = shortcut.modifiers
        if flags.contains(.control) { components.append("⌃") }
        if flags.contains(.option) { components.append("⌥") }
        if flags.contains(.shift) { components.append("⇧") }
        if flags.contains(.command) { components.append("⌘") }
        if let key = KeyTransformer.displayName(for: shortcut.keyCode) {
            components.append(key)
        } else {
            components.append(String(format: "%02X", shortcut.keyCode))
        }
        return components.joined(separator: " ")
    }

    private func preset(for id: String) -> FocusPreset? {
        if let match = availablePresets.first(where: { $0.id == id }) {
            return match
        }
        if let fallback = availablePresets.first {
            selectedPresetID = fallback.id
            return fallback
        }
        return nil
    }
}

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
