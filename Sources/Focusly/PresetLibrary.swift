/// Central catalog of built-in overlay presets, localized at access time.
@MainActor
struct PresetLibrary {
    /// Returns all preset options, using the current localization to title each entry.
    @MainActor static var presets: [FocusPreset] {
        let localization = LocalizationService.shared
        return [
            FocusPreset(id: "focus", name: localization.localized("Blur (Focus)", fallback: "Blur (Focus)"), style: .blurFocus),
            FocusPreset(id: "warm", name: localization.localized("Warm", fallback: "Warm"), style: .warm),
            FocusPreset(id: "colorful", name: localization.localized("Colorful", fallback: "Colorful"), style: .colorful),
            FocusPreset(id: "monochrome", name: localization.localized("Monochrome", fallback: "Monochrome"), style: .monochrome)
        ]
    }

    /// Looks up a preset by identifier, handling legacy aliases for backwards compatibility.
    static func preset(withID id: String) -> FocusPreset {
        let currentPresets = presets
        if let preset = currentPresets.first(where: { $0.id == id }) {
            return preset
        }
        if let mappedID = legacyIDMapping[id],
           let preset = currentPresets.first(where: { $0.id == mappedID }) {
            return preset
        }
        return currentPresets[0]
    }

    /// Maintains compatibility with older preset identifiers persisted to disk.
    private static let legacyIDMapping: [String: String] = [
        "ember": "warm",
        "vibe": "colorful"
    ]
}
