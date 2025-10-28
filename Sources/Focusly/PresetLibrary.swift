@MainActor
struct PresetLibrary {
    @MainActor static var presets: [FocusPreset] {
        let localization = LocalizationService.shared
        return [
            FocusPreset(id: "focus", name: localization.localized("Blur (Focus)", fallback: "Blur (Focus)"), style: .blurFocus),
            FocusPreset(id: "warm", name: localization.localized("Warm", fallback: "Warm"), style: .warm),
            FocusPreset(id: "colorful", name: localization.localized("Colorful", fallback: "Colorful"), style: .colorful),
            FocusPreset(id: "monochrome", name: localization.localized("Monochrome", fallback: "Monochrome"), style: .monochrome)
        ]
    }

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

    private static let legacyIDMapping: [String: String] = [
        "ember": "warm",
        "vibe": "colorful"
    ]
}
