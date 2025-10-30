import Foundation

/// Persists overlay presets and per-display overrides to user defaults.
@MainActor
final class ProfileStore {
    /// Codable payload saved to disk that captures the selected preset and overrides.
    struct State: Codable, Equatable {
        var selectedPresetID: String
        var displayOverrides: [DisplayID: FocusOverlayStyle]
    }

    private let userDefaults: UserDefaults
    private let stateDefaultsKey = "Focusly.ProfileStore.State"
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    private(set) var profileState: State {
        didSet { persistProfileState() }
    }

    /// Loads persisted state or seeds defaults when the app runs for the first time.
    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: stateDefaultsKey),
           let decoded = try? jsonDecoder.decode(State.self, from: data) {
            profileState = decoded
        } else {
            profileState = State(
                selectedPresetID: PresetLibrary.presets.first?.id ?? "focus",
                displayOverrides: [:]
            )
            persistProfileState()
        }
    }

    /// Selects a new preset and clears overrides so displays inherit the new look.
    func selectPreset(_ preset: FocusPreset) {
        guard profileState.selectedPresetID != preset.id else { return }
        profileState.selectedPresetID = preset.id
        profileState.displayOverrides = [:]
    }

    /// Returns the appropriate overlay style for a display, falling back to the active preset.
    func style(forDisplayID displayID: DisplayID) -> FocusOverlayStyle {
        if let override = profileState.displayOverrides[displayID] {
            return override
        }
        return PresetLibrary.preset(withID: profileState.selectedPresetID).style
    }

    /// Stores a per-display override.
    func updateStyle(_ style: FocusOverlayStyle, forDisplayID displayID: DisplayID) {
        profileState.displayOverrides[displayID] = style
    }

    /// Removes any per-display override for the given display.
    func resetOverride(forDisplayID displayID: DisplayID) {
        profileState.displayOverrides.removeValue(forKey: displayID)
    }

    /// Drops overrides for displays that are no longer connected.
    func removeInvalidOverrides(validDisplayIDs: Set<DisplayID>) {
        let filtered = profileState.displayOverrides.filter { validDisplayIDs.contains($0.key) }
        if filtered.count != profileState.displayOverrides.count {
            profileState.displayOverrides = filtered
        }
    }

    /// Returns the currently selected preset model.
    func currentPreset() -> FocusPreset {
        PresetLibrary.preset(withID: profileState.selectedPresetID)
    }

    /// Serializes the profile state to user defaults.
    private func persistProfileState() {
        guard let data = try? jsonEncoder.encode(profileState) else { return }
        userDefaults.set(data, forKey: stateDefaultsKey)
    }
}
