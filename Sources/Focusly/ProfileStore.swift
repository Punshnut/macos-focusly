import Foundation

@MainActor
final class ProfileStore {
    struct State: Codable, Equatable {
        var selectedPresetID: String
        var displayOverrides: [DisplayID: FocusOverlayStyle]
    }

    private let defaults: UserDefaults
    private let stateKey = "Focusly.ProfileStore.State"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private(set) var state: State {
        didSet { persist() }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: stateKey),
           let decoded = try? decoder.decode(State.self, from: data) {
            state = decoded
        } else {
            state = State(
                selectedPresetID: PresetLibrary.presets.first?.id ?? "focus",
                displayOverrides: [:]
            )
            persist()
        }
    }

    func selectPreset(_ preset: FocusPreset) {
        guard state.selectedPresetID != preset.id else { return }
        state.selectedPresetID = preset.id
        state.displayOverrides = [:]
    }

    func style(forDisplayID displayID: DisplayID) -> FocusOverlayStyle {
        if let override = state.displayOverrides[displayID] {
            return override
        }
        return PresetLibrary.preset(withID: state.selectedPresetID).style
    }

    func updateStyle(_ style: FocusOverlayStyle, forDisplayID displayID: DisplayID) {
        state.displayOverrides[displayID] = style
    }

    func resetOverride(forDisplayID displayID: DisplayID) {
        state.displayOverrides.removeValue(forKey: displayID)
    }

    func removeInvalidOverrides(validDisplayIDs: Set<DisplayID>) {
        let filtered = state.displayOverrides.filter { validDisplayIDs.contains($0.key) }
        if filtered.count != state.displayOverrides.count {
            state.displayOverrides = filtered
        }
    }

    func currentPreset() -> FocusPreset {
        PresetLibrary.preset(withID: state.selectedPresetID)
    }

    private func persist() {
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }
}
