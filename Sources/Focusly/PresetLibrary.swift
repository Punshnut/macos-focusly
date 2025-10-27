import Foundation

struct PresetLibrary {
    static let presets: [FocusPreset] = [
        FocusPreset(id: "focus", name: localized("Blur (Focus)"), style: .blurFocus),
        FocusPreset(id: "warm", name: localized("Warm"), style: .warm),
        FocusPreset(id: "colorful", name: localized("Colorful"), style: .colorful),
        FocusPreset(id: "monochrome", name: localized("Monochrome"), style: .monochrome)
    ]

    static func preset(withID id: String) -> FocusPreset {
        if let preset = presets.first(where: { $0.id == id }) {
            return preset
        }
        if let mappedID = legacyIDMapping[id],
           let preset = presets.first(where: { $0.id == mappedID }) {
            return preset
        }
        return presets[0]
    }

    private static func localized(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .module, value: key, comment: "")
    }

    private static let legacyIDMapping: [String: String] = [
        "ember": "warm",
        "vibe": "colorful"
    ]
}
