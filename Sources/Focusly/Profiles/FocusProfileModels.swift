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

struct FocusOverlayStyle: Codable, Equatable {
    var opacity: Double
    var blurRadius: Double
    var tint: FocusTint
    var animationDuration: TimeInterval

    static let blurFocus = FocusOverlayStyle(opacity: 0.78, blurRadius: 38, tint: .neutral, animationDuration: 0.28)
    static let warm = FocusOverlayStyle(opacity: 0.82, blurRadius: 44, tint: .ember, animationDuration: 0.36)
    static let colorful = FocusOverlayStyle(opacity: 0.88, blurRadius: 50, tint: .lagoon, animationDuration: 0.32)
    static let monochrome = FocusOverlayStyle(opacity: 0.80, blurRadius: 42, tint: .slate, animationDuration: 0.30)

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
