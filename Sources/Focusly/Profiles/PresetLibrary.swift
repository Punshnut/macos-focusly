import Foundation

struct PresetLibrary {
    static let presets: [FocusPreset] = [
        FocusPreset(id: "focus", name: localized("Focus"), style: .focus),
        FocusPreset(id: "vibe", name: localized("Glow"), style: .vibe),
        FocusPreset(id: "ember", name: localized("Warm"), style: .ember)
    ]

    static func preset(withID id: String) -> FocusPreset {
        presets.first { $0.id == id } ?? presets[0]
    }

    private static func localized(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .module, value: key, comment: "")
    }
}
