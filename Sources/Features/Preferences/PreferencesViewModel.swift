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
        var blurMaterial: FocusOverlayMaterial
        var blurRadius: Double
        var isExcluded: Bool

        var tintPreview: NSColor {
            tint
        }
    }

    /// Visual representation of an ignored application row.
    struct ApplicationException: Identifiable, Equatable {
        let id: String
        var bundleIdentifier: String
        var displayName: String
        var icon: NSImage?
        var preference: ApplicationMaskingIgnoreList.Preference
        var isUserDefined: Bool
    }

    /// Glue closures that let the preferences UI trigger app-level changes.
    struct Callbacks {
        /// Glue closure bundle so the view model can stay UI focused without knowing about app coordination.
        var onDisplayChange: (DisplayID, FocusOverlayStyle) -> Void
        var onDisplayReset: (DisplayID) -> Void
        var onRequestShortcutCapture: (HotkeyAction, @escaping (HotkeyShortcut?) -> Void) -> Void
        var onUpdateShortcut: (HotkeyAction, HotkeyShortcut?) -> Void
        var onToggleHotkeys: (HotkeyAction, Bool) -> Void
        var onToggleLaunchAtLogin: (Bool) -> Void
        var onRequestOnboarding: () -> Void
        var onUpdateStatusIconStyle: (StatusBarIconStyle) -> Void
        var onSelectPreset: (FocusPreset) -> Void
        var onSelectLanguage: (String) -> Void
        var onUpdateTrackingProfile: (WindowTrackingProfile) -> Void
        var onToggleDisplayExclusion: (DisplayID, Bool) -> Void
        var onTogglePreferencesWindowGlassy: (Bool) -> Void
        var onUpdateApplicationException: (ApplicationMaskingIgnoreList.Entry) -> Void
        var onRemoveApplicationExceptions: ([String]) -> Void
    }

    @Published var displaySettings: [DisplaySettings]
    @Published var presetOptions: [FocusPreset]
    @Published var selectedPresetIdentifier: String
    @Published var isLaunchAtLoginEnabled: Bool
    @Published var isLaunchAtLoginAvailable: Bool
    @Published var launchAtLoginStatusMessage: String?
    @Published private var hotkeyStates: [HotkeyAction: HotkeyState]
    @Published private(set) var capturingHotkey: HotkeyAction?
    @Published var statusIconStyle: StatusBarIconStyle
    @Published var trackingProfile: WindowTrackingProfile
    @Published var preferencesWindowGlassy: Bool
    @Published var applicationExceptions: [ApplicationException]
    /// App coordination closures invoked when preferences mutate shared state.
    private let callbacks: Callbacks
    let iconStyleOptions: [StatusBarIconStyle]
    let trackingProfileOptions: [WindowTrackingProfile]
    let hotkeyActions: [HotkeyAction] = HotkeyAction.allCases

    /// User-facing representation of a single hotkey preference row.
    struct HotkeyState {
        var shortcut: HotkeyShortcut?
        var isEnabled: Bool
    }

    /// Creates the view model with the current overlay, shortcut, and status bar state.
    init(
        displaySettings: [DisplaySettings],
        isLaunchAtLoginEnabled: Bool,
        isLaunchAtLoginAvailable: Bool,
        launchAtLoginStatusMessage: String?,
        hotkeyStates: [HotkeyAction: HotkeyState],
        statusIconStyle: StatusBarIconStyle,
        iconStyleOptions: [StatusBarIconStyle],
        presetOptions: [FocusPreset],
        selectedPresetIdentifier: String,
        trackingProfile: WindowTrackingProfile,
        trackingProfileOptions: [WindowTrackingProfile],
        preferencesWindowGlassy: Bool,
        applicationEntries: [ApplicationMaskingIgnoreList.Entry],
        suggestedApplicationEntries: [ApplicationMaskingIgnoreList.Entry],
        callbacks: Callbacks
    ) {
        self.displaySettings = displaySettings
        self.presetOptions = presetOptions
        self.selectedPresetIdentifier = selectedPresetIdentifier
        self.isLaunchAtLoginEnabled = isLaunchAtLoginEnabled
        self.isLaunchAtLoginAvailable = isLaunchAtLoginAvailable
        self.launchAtLoginStatusMessage = launchAtLoginStatusMessage
        self.hotkeyStates = PreferencesViewModel.normalizeHotkeyStates(hotkeyStates)
        self.callbacks = callbacks
        self.statusIconStyle = statusIconStyle
        self.iconStyleOptions = iconStyleOptions
        self.trackingProfile = trackingProfile
        self.trackingProfileOptions = trackingProfileOptions
        self.preferencesWindowGlassy = preferencesWindowGlassy
        self.applicationExceptions = PreferencesViewModel.makeApplicationExceptions(
            userEntries: applicationEntries,
            suggestedEntries: suggestedApplicationEntries
        )
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

    /// Persists blur material adjustments for a display and notifies the app.
    func updateBlurMaterial(for displayID: DisplayID, material: FocusOverlayMaterial) {
        guard let settingsIndex = displaySettings.firstIndex(where: { $0.id == displayID }) else { return }
        guard displaySettings[settingsIndex].blurMaterial != material else { return }
        displaySettings[settingsIndex].blurMaterial = material
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
            displaySettings[settingsIndex].blurMaterial = sourceDisplaySettings.blurMaterial
            displaySettings[settingsIndex].blurRadius = sourceDisplaySettings.blurRadius
            commit(displaySettings: displaySettings[settingsIndex])
        }
    }

    /// Toggles the launch-at-login setting when the feature is supported.
    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard isLaunchAtLoginAvailable else { return }
        isLaunchAtLoginEnabled = enabled
        callbacks.onToggleLaunchAtLogin(enabled)
    }

    /// Returns whether a specific hotkey toggle is enabled.
    func isHotkeyEnabled(_ action: HotkeyAction) -> Bool {
        hotkeyStates[action]?.isEnabled ?? true
    }

    /// Returns a description of the shortcut bound to the supplied action.
    func shortcutSummary(for action: HotkeyAction) -> String {
        PreferencesViewModel.describeShortcut(hotkeyStates[action]?.shortcut)
    }
    
    /// Indicates whether the supplied action currently has a shortcut bound.
    func hasShortcut(for action: HotkeyAction) -> Bool {
        hotkeyStates[action]?.shortcut != nil
    }

    /// Enables or disables a single hotkey action.
    func setHotkeyEnabled(_ enabled: Bool, for action: HotkeyAction) {
        mutateHotkeyState(for: action) { state in
            state.isEnabled = enabled
        }
        callbacks.onToggleHotkeys(action, enabled)
    }

    /// Initiates capturing a new shortcut and updates state when recording finishes.
    func beginShortcutCapture(for action: HotkeyAction) {
        capturingHotkey = action
        callbacks.onRequestShortcutCapture(action) { [weak self] shortcut in
            guard let self else { return }
            self.capturingHotkey = nil
            self.mutateHotkeyState(for: action) { state in
                state.shortcut = shortcut
            }
            self.callbacks.onUpdateShortcut(action, shortcut)
        }
    }

    /// Removes the current shortcut so no global hotkey remains registered.
    func clearShortcut(for action: HotkeyAction) {
        mutateHotkeyState(for: action) { state in
            state.shortcut = nil
        }
        callbacks.onUpdateShortcut(action, nil)
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

    /// Toggles whether the preferences window should keep the glassy material.
    func setPreferencesWindowGlassy(_ isGlassy: Bool) {
        guard preferencesWindowGlassy != isGlassy else { return }
        preferencesWindowGlassy = isGlassy
        callbacks.onTogglePreferencesWindowGlassy(isGlassy)
    }

    /// Requests that the onboarding sequence be shown again.
    func showOnboarding() {
        callbacks.onRequestOnboarding()
    }

    /// Applies an externally provided shortcut (e.g., after persistence changes).
    func applyShortcut(_ activeShortcut: HotkeyShortcut?, for action: HotkeyAction) {
        mutateHotkeyState(for: action) { state in
            state.shortcut = activeShortcut
        }
    }

    /// Replaces the entire hotkey map with a fresh snapshot.
    func updateHotkeys(_ states: [HotkeyAction: HotkeyState]) {
        hotkeyStates = PreferencesViewModel.normalizeHotkeyStates(states)
    }

    /// Updates a single hotkey state without triggering callbacks.
    func updateHotkeyState(_ state: HotkeyState, for action: HotkeyAction) {
        var updated = hotkeyStates
        updated[action] = state
        hotkeyStates = updated
    }

    /// Replaces the current set of ignored applications.
    func refreshApplicationExceptions(
        userEntries: [ApplicationMaskingIgnoreList.Entry],
        suggestedEntries: [ApplicationMaskingIgnoreList.Entry]
    ) {
        applicationExceptions = PreferencesViewModel.makeApplicationExceptions(
            userEntries: userEntries,
            suggestedEntries: suggestedEntries
        )
    }

    /// Imports an application bundle from disk so it can be ignored during masking.
    func importApplication(at url: URL) {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return }
        let normalizedID = identifier.focuslyNormalizedToken() ?? identifier.lowercased()
        let friendlyName = FileManager.default.displayName(atPath: url.path)
        let displayName = friendlyName.isEmpty ? identifier : friendlyName
        let icon = PreferencesViewModel.icon(forApplicationAt: url)
        let existingPreference = applicationExceptions.first(where: { $0.id == normalizedID })?.preference ?? .excludeCompletely
        upsertApplicationException(ApplicationException(
            id: normalizedID,
            bundleIdentifier: identifier,
            displayName: displayName,
            icon: icon,
            preference: existingPreference,
            isUserDefined: true
        ), persistPreference: true)
    }

    /// Updates the preference mode for the supplied application.
    func updateApplicationPreference(for bundleIdentifier: String, preference: ApplicationMaskingIgnoreList.Preference) {
        let normalized = bundleIdentifier.focuslyNormalizedToken() ?? bundleIdentifier.lowercased()
        guard let index = applicationExceptions.firstIndex(where: { $0.id == normalized }) else { return }
        guard applicationExceptions[index].preference != preference else { return }
        applicationExceptions[index].preference = preference
        applicationExceptions[index].isUserDefined = true
        callbacks.onUpdateApplicationException(ApplicationMaskingIgnoreList.Entry(
            bundleIdentifier: applicationExceptions[index].bundleIdentifier,
            preference: preference
        ))
    }

    /// Removes a collection of applications from the ignore list.
    func removeApplications(withIDs identifiers: [String]) {
        guard canRemoveApplications(withIDs: identifiers) else { return }
        let normalizedSet = Set(identifiers.map { $0.focuslyNormalizedToken() ?? $0.lowercased() })
        let removedBundles = applicationExceptions
            .filter { normalizedSet.contains($0.id) && $0.isUserDefined }
            .map(\.bundleIdentifier)
        guard !removedBundles.isEmpty else { return }
        applicationExceptions.removeAll { normalizedSet.contains($0.id) && $0.isUserDefined }
        callbacks.onRemoveApplicationExceptions(removedBundles)
    }

    /// Indicates whether the current selection can be removed.
    func canRemoveApplications(withIDs identifiers: [String]) -> Bool {
        guard !identifiers.isEmpty else { return false }
        let normalized = identifiers.map { $0.focuslyNormalizedToken() ?? $0.lowercased() }
        for id in normalized {
            guard let match = applicationExceptions.first(where: { $0.id == id }), match.isUserDefined else {
                return false
            }
        }
        return true
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
            blurMaterial: displaySettings.blurMaterial,
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

    private static func normalizeHotkeyStates(_ states: [HotkeyAction: HotkeyState]) -> [HotkeyAction: HotkeyState] {
        var normalized = states
        for action in HotkeyAction.allCases where normalized[action] == nil {
            normalized[action] = HotkeyState(shortcut: nil, isEnabled: true)
        }
        return normalized
    }

    private func upsertApplicationException(_ exception: ApplicationException, persistPreference: Bool) {
        if let index = applicationExceptions.firstIndex(where: { $0.id == exception.id }) {
            applicationExceptions[index] = exception
        } else {
            applicationExceptions.append(exception)
        }
        applicationExceptions.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        guard persistPreference else { return }
        callbacks.onUpdateApplicationException(ApplicationMaskingIgnoreList.Entry(
            bundleIdentifier: exception.bundleIdentifier,
            preference: exception.preference
        ))
    }

    private static func makeApplicationExceptions(
        userEntries: [ApplicationMaskingIgnoreList.Entry],
        suggestedEntries: [ApplicationMaskingIgnoreList.Entry]
    ) -> [ApplicationException] {
        let workspace = NSWorkspace.shared
        let fileManager = FileManager.default
        var results: [ApplicationException] = []
        var seen: Set<String> = []

        func append(entry: ApplicationMaskingIgnoreList.Entry, isUserDefined: Bool) {
            let normalized = entry.bundleIdentifier.focuslyNormalizedToken() ?? entry.bundleIdentifier.lowercased()
            guard !normalized.isEmpty else { return }
            guard !seen.contains(normalized) else { return }
            seen.insert(normalized)

            let resolvedURL = workspace.urlForApplication(withBundleIdentifier: entry.bundleIdentifier)
            let displayName: String
            if let url = resolvedURL {
                let friendly = fileManager.displayName(atPath: url.path)
                displayName = friendly.isEmpty ? entry.bundleIdentifier : friendly
            } else {
                displayName = entry.bundleIdentifier
            }
            let iconImage = resolvedURL.flatMap { icon(forApplicationAt: $0) }
                ?? icon(forBundleIdentifier: entry.bundleIdentifier, workspace: workspace)

            results.append(ApplicationException(
                id: normalized,
                bundleIdentifier: entry.bundleIdentifier,
                displayName: displayName,
                icon: iconImage,
                preference: entry.preference,
                isUserDefined: isUserDefined
            ))
        }

        userEntries.forEach { append(entry: $0, isUserDefined: true) }
        suggestedEntries.forEach { append(entry: $0, isUserDefined: false) }

        return results.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func icon(forBundleIdentifier identifier: String, workspace: NSWorkspace) -> NSImage? {
        guard let url = workspace.urlForApplication(withBundleIdentifier: identifier) else {
            return nil
        }
        return icon(forApplicationAt: url)
    }

    private static func icon(forApplicationAt url: URL) -> NSImage? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 28, height: 28)
        return icon
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

private extension PreferencesViewModel {
    func mutateHotkeyState(for action: HotkeyAction, mutation: (inout HotkeyState) -> Void) {
        var updated = hotkeyStates
        var state = updated[action] ?? HotkeyState(shortcut: nil, isEnabled: true)
        mutation(&state)
        updated[action] = state
        hotkeyStates = updated
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
