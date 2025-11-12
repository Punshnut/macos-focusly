import Foundation

/// Persists overlay presets and per-display overrides to user defaults.
@MainActor
final class ProfileStore {
    /// Codable payload saved to disk that captures the selected preset and overrides.
    struct State: Codable, Equatable {
        var selectedPresetID: String
        var displayOverrides: [DisplayID: FocusOverlayStyle]
        var excludedDisplays: Set<DisplayID>

        init(
            selectedPresetID: String,
            displayOverrides: [DisplayID: FocusOverlayStyle],
            excludedDisplays: Set<DisplayID> = []
        ) {
            self.selectedPresetID = selectedPresetID
            self.displayOverrides = displayOverrides
            self.excludedDisplays = excludedDisplays
        }

        private enum CodingKeys: String, CodingKey {
            case selectedPresetID
            case displayOverrides
            case excludedDisplays
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            selectedPresetID = try container.decode(String.self, forKey: .selectedPresetID)
            displayOverrides = try container.decode([DisplayID: FocusOverlayStyle].self, forKey: .displayOverrides)
            excludedDisplays = try container.decodeIfPresent(Set<DisplayID>.self, forKey: .excludedDisplays) ?? []
        }

        /// Persists the profile state so it can be restored on the next launch.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(selectedPresetID, forKey: .selectedPresetID)
            try container.encode(displayOverrides, forKey: .displayOverrides)
            if !excludedDisplays.isEmpty {
                try container.encode(excludedDisplays, forKey: .excludedDisplays)
            }
        }
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
        if let persistedData = userDefaults.data(forKey: stateDefaultsKey),
           let decodedState = try? jsonDecoder.decode(State.self, from: persistedData) {
            profileState = decodedState
        } else {
            profileState = State(
                selectedPresetID: PresetLibrary.presets.first?.id ?? "focus",
                displayOverrides: [:],
                excludedDisplays: []
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
        let validOverrides = profileState.displayOverrides.filter { validDisplayIDs.contains($0.key) }
        if validOverrides.count != profileState.displayOverrides.count {
            profileState.displayOverrides = validOverrides
        }
        let validExcluded = profileState.excludedDisplays.filter { validDisplayIDs.contains($0) }
        if validExcluded.count != profileState.excludedDisplays.count {
            profileState.excludedDisplays = Set(validExcluded)
        }
    }

    /// Returns the currently selected preset model.
    func currentPreset() -> FocusPreset {
        PresetLibrary.preset(withID: profileState.selectedPresetID)
    }

    /// Checks whether the supplied display should be excluded from overlay rendering.
    func isDisplayExcluded(_ displayID: DisplayID) -> Bool {
        profileState.excludedDisplays.contains(displayID)
    }

    /// Updates the exclusion flag for a particular display.
    func setDisplay(_ displayID: DisplayID, excluded: Bool) {
        if excluded {
            profileState.excludedDisplays.insert(displayID)
        } else if profileState.excludedDisplays.contains(displayID) {
            profileState.excludedDisplays.remove(displayID)
        }
    }

    /// Serializes the profile state to user defaults.
    private func persistProfileState() {
        guard let encodedState = try? jsonEncoder.encode(profileState) else { return }
        userDefaults.set(encodedState, forKey: stateDefaultsKey)
    }
}
