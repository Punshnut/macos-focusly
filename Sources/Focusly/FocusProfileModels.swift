import AppKit

struct FocusTint: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let neutral = FocusTint(red: 0.12, green: 0.16, blue: 0.20, alpha: 0.75)
    static let ember = FocusTint(red: 0.62, green: 0.21, blue: 0.13, alpha: 0.78)
    static let lagoon = FocusTint(red: 0.10, green: 0.36, blue: 0.52, alpha: 0.72)
    static let slate = FocusTint(red: 0.20, green: 0.23, blue: 0.27, alpha: 0.82)

    func makeColor() -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}

enum FocusOverlayColorTreatment: String, Codable {
    case preserveColor
    case monochrome
}

struct FocusOverlayStyle: Codable, Equatable {
    var opacity: Double
    var blurRadius: Double
    var tint: FocusTint
    var animationDuration: TimeInterval
    var colorTreatment: FocusOverlayColorTreatment = .preserveColor

    init(
        opacity: Double,
        blurRadius: Double,
        tint: FocusTint,
        animationDuration: TimeInterval,
        colorTreatment: FocusOverlayColorTreatment = .preserveColor
    ) {
        self.opacity = opacity
        self.blurRadius = blurRadius
        self.tint = tint
        self.animationDuration = animationDuration
        self.colorTreatment = colorTreatment
    }

    private enum CodingKeys: String, CodingKey {
        case opacity
        case blurRadius
        case tint
        case animationDuration
        case colorTreatment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        opacity = try container.decode(Double.self, forKey: .opacity)
        blurRadius = try container.decode(Double.self, forKey: .blurRadius)
        tint = try container.decode(FocusTint.self, forKey: .tint)
        animationDuration = try container.decode(TimeInterval.self, forKey: .animationDuration)
        colorTreatment = try container.decodeIfPresent(FocusOverlayColorTreatment.self, forKey: .colorTreatment) ?? .preserveColor
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(blurRadius, forKey: .blurRadius)
        try container.encode(tint, forKey: .tint)
        try container.encode(animationDuration, forKey: .animationDuration)
        try container.encode(colorTreatment, forKey: .colorTreatment)
    }

    static let blurFocus = FocusOverlayStyle(opacity: 0.78, blurRadius: 38, tint: .neutral, animationDuration: 0.28)
    static let warm = FocusOverlayStyle(opacity: 0.82, blurRadius: 44, tint: .ember, animationDuration: 0.36)
    static let colorful = FocusOverlayStyle(opacity: 0.88, blurRadius: 50, tint: .lagoon, animationDuration: 0.32)
    static let monochrome = FocusOverlayStyle(opacity: 0.80, blurRadius: 42, tint: .slate, animationDuration: 0.30, colorTreatment: .monochrome)

    // Legacy aliases preserved for backwards compatibility with persisted data.
    static let focus = blurFocus
    static let vibe = colorful
    static let ember = warm
}

struct FocusPreset: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var style: FocusOverlayStyle
}
