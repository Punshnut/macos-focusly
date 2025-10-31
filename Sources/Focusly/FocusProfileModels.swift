import AppKit

/// Codable tint definition that drives overlay colorization.
struct FocusTint: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let neutral = FocusTint(red: 0.12, green: 0.16, blue: 0.20, alpha: 0.75)
    static let ember = FocusTint(red: 0.62, green: 0.21, blue: 0.13, alpha: 0.78)
    static let lagoon = FocusTint(red: 0.10, green: 0.36, blue: 0.52, alpha: 0.72)
    static let slate = FocusTint(red: 0.20, green: 0.23, blue: 0.27, alpha: 0.82)

    /// Translates the serialized tint into an `NSColor` for rendering.
    func makeColor() -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Granular options for how the overlay should treat captured window colors.
enum FocusOverlayColorTreatment: String, Codable, CaseIterable {
    case preserveColor
    case monochrome

    /// Human readable label for UI display.
    var displayName: String {
        switch self {
        case .preserveColor:
            return "Preserve Color"
        case .monochrome:
            return "Monochrome"
        }
    }
}

/// Persisted style representation consumed by the overlay renderer.
struct FocusOverlayStyle: Codable, Equatable {
    var opacity: Double
    var tint: FocusTint
    var animationDuration: TimeInterval
    var colorTreatment: FocusOverlayColorTreatment = .preserveColor
    var blurRadius: Double = 35

    init(
        opacity: Double,
        tint: FocusTint,
        animationDuration: TimeInterval,
        colorTreatment: FocusOverlayColorTreatment = .preserveColor,
        blurRadius: Double = 35
    ) {
        self.opacity = opacity
        self.tint = tint
        self.animationDuration = animationDuration
        self.colorTreatment = colorTreatment
        self.blurRadius = blurRadius
    }

    private enum CodingKeys: String, CodingKey {
        case opacity
        case tint
        case animationDuration
        case colorTreatment
        case blurRadius // Legacy payloads encoded a blur radius; now respected.
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        opacity = try container.decode(Double.self, forKey: .opacity)
        tint = try container.decode(FocusTint.self, forKey: .tint)
        animationDuration = try container.decode(TimeInterval.self, forKey: .animationDuration)
        colorTreatment = try container.decodeIfPresent(FocusOverlayColorTreatment.self, forKey: .colorTreatment) ?? .preserveColor
        blurRadius = try container.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 35
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(tint, forKey: .tint)
        try container.encode(animationDuration, forKey: .animationDuration)
        try container.encode(colorTreatment, forKey: .colorTreatment)
        try container.encode(blurRadius, forKey: .blurRadius)
    }

    static let blurFocus = FocusOverlayStyle(opacity: 0.78, tint: .neutral, animationDuration: 0.28, blurRadius: 38)
    static let warm = FocusOverlayStyle(opacity: 0.82, tint: .ember, animationDuration: 0.36, blurRadius: 32)
    static let colorful = FocusOverlayStyle(opacity: 0.88, tint: .lagoon, animationDuration: 0.32, blurRadius: 28)
    static let monochrome = FocusOverlayStyle(opacity: 0.80, tint: .slate, animationDuration: 0.30, colorTreatment: .monochrome, blurRadius: 35)

    // Legacy aliases preserved for backwards compatibility with persisted data.
    static let focus = blurFocus
    static let vibe = colorful
    static let ember = warm
}

/// User-facing preset that bundles metadata with a concrete overlay style.
struct FocusPreset: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var style: FocusOverlayStyle
}
