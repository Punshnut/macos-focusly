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
    static let ink = FocusTint(red: 0.06, green: 0.07, blue: 0.09, alpha: 0.88)
    static let frost = FocusTint(red: 0.90, green: 0.93, blue: 0.97, alpha: 0.78)
    static let paper = FocusTint(red: 0.97, green: 0.95, blue: 0.88, alpha: 0.82)

    /// Translates the serialized tint into an `NSColor` for rendering.
    func makeColor() -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Granular options for how the overlay should treat captured window colors.
enum FocusOverlayColorTreatment: String, Codable, CaseIterable {
    case preserveColor
    case dark
    case whiteOverlay

    /// Maintains control over the display order surfaced in pickers.
    static var allCases: [FocusOverlayColorTreatment] { [.preserveColor, .dark, .whiteOverlay] }

    /// Human readable label for UI display.
    var displayName: String {
        switch self {
        case .preserveColor:
            return "Preserve Color"
        case .dark:
            return "Dark"
        case .whiteOverlay:
            return "White"
        }
    }

    /// Supports decoding legacy payloads that persisted the previous `monochrome` case.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if let treatment = FocusOverlayColorTreatment(rawValue: rawValue) {
            self = treatment
            return
        }
        if rawValue == "monochrome" {
            self = .dark
            return
        }
        self = .preserveColor
    }

    /// Persists the canonical raw value for new payloads.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Discrete macOS blur materials Focusly can apply behind its tint overlay.
enum FocusOverlayMaterial: String, Codable, CaseIterable, Equatable {
    case hudWindow
    case menu
    case popover
    case sidebar
    case sheet
    case fullScreenUI
    case windowBackground

    /// Resolves the underlying `NSVisualEffectView.Material`.
    var visualEffectMaterial: NSVisualEffectView.Material {
        switch self {
        case .hudWindow:
            return .hudWindow
        case .menu:
            return .menu
        case .popover:
            return .popover
        case .sidebar:
            return .sidebar
        case .sheet:
            return .sheet
        case .fullScreenUI:
            return .fullScreenUI
        case .windowBackground:
            return .windowBackground
        }
    }

    /// Spoken label exposed to VoiceOver to describe the current material.
    var accessibilityDescription: String {
        switch self {
        case .hudWindow:
            return NSLocalizedString(
                "HUD Window Blur",
                comment: "Accessibility description for the HUD window blur material option."
            )
        case .menu:
            return NSLocalizedString(
                "Menu Blur",
                comment: "Accessibility description for the menu blur material option."
            )
        case .popover:
            return NSLocalizedString(
                "Popover Blur",
                comment: "Accessibility description for the popover blur material option."
            )
        case .sidebar:
            return NSLocalizedString(
                "Sidebar Blur",
                comment: "Accessibility description for the sidebar blur material option."
            )
        case .sheet:
            return NSLocalizedString(
                "Sheet Blur",
                comment: "Accessibility description for the sheet blur material option."
            )
        case .fullScreenUI:
            return NSLocalizedString(
                "Full Screen Blur",
                comment: "Accessibility description for the full-screen blur material option."
            )
        case .windowBackground:
            return NSLocalizedString(
                "Window Background Blur",
                comment: "Accessibility description for the window background blur material option."
            )
        }
    }
}

/// Persisted style representation consumed by the overlay renderer.
struct FocusOverlayStyle: Codable, Equatable {
    var opacity: Double
    var tint: FocusTint
    var animationDuration: TimeInterval
    var colorTreatment: FocusOverlayColorTreatment = .preserveColor
    var blurMaterial: FocusOverlayMaterial = .hudWindow
    var blurRadius: Double = 35

    init(
        opacity: Double,
        tint: FocusTint,
        animationDuration: TimeInterval,
        colorTreatment: FocusOverlayColorTreatment = .preserveColor,
        blurMaterial: FocusOverlayMaterial = .hudWindow,
        blurRadius: Double = 35
    ) {
        self.opacity = opacity
        self.tint = tint
        self.animationDuration = animationDuration
        self.colorTreatment = colorTreatment
        self.blurMaterial = blurMaterial
        self.blurRadius = blurRadius
    }

    private enum CodingKeys: String, CodingKey {
        case opacity
        case tint
        case animationDuration
        case colorTreatment
        case blurMaterial
        case blurRadius // Legacy payloads encoded a blur radius; now respected.
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        opacity = try container.decode(Double.self, forKey: .opacity)
        tint = try container.decode(FocusTint.self, forKey: .tint)
        animationDuration = try container.decode(TimeInterval.self, forKey: .animationDuration)
        colorTreatment = try container.decodeIfPresent(FocusOverlayColorTreatment.self, forKey: .colorTreatment) ?? .preserveColor
        blurMaterial = try container.decodeIfPresent(FocusOverlayMaterial.self, forKey: .blurMaterial) ?? .hudWindow
        blurRadius = try container.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 35
    }

    /// Serializes the style so it can be stored alongside presets or per-display overrides.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(tint, forKey: .tint)
        try container.encode(animationDuration, forKey: .animationDuration)
        try container.encode(colorTreatment, forKey: .colorTreatment)
        try container.encode(blurMaterial, forKey: .blurMaterial)
        try container.encode(blurRadius, forKey: .blurRadius)
    }

    static let blurFocus = FocusOverlayStyle(opacity: 0.78, tint: .neutral, animationDuration: 0.28, blurRadius: 38)
    static let warm = FocusOverlayStyle(opacity: 0.82, tint: .ember, animationDuration: 0.36, blurRadius: 32)
    static let colorful = FocusOverlayStyle(opacity: 0.88, tint: .lagoon, animationDuration: 0.32, blurRadius: 28)
    static let dark = FocusOverlayStyle(opacity: 0.88, tint: .ink, animationDuration: 0.30, colorTreatment: .dark, blurRadius: 38)
    static let whiteOverlay = FocusOverlayStyle(opacity: 0.86, tint: .frost, animationDuration: 0.28, colorTreatment: .whiteOverlay, blurRadius: 34)
    static let paper = FocusOverlayStyle(opacity: 0.86, tint: .paper, animationDuration: 0.32, colorTreatment: .whiteOverlay, blurRadius: 30)
    static let monochrome = dark // Legacy alias preserved until a true monochrome treatment returns.

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
