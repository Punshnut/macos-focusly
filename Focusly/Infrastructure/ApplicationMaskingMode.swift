import Foundation

/// Determines how Focusly carves out windows that belong to the active application.
enum ApplicationMaskingMode: String, Codable, Equatable {
    /// Only expose the focused window while masking the rest of the app.
    case focusedWindow
    /// Reveal every on-screen window owned by the active application.
    case allApplicationWindows

    /// Toggles between the supported modes.
    var toggled: ApplicationMaskingMode {
        switch self {
        case .focusedWindow:
            return .allApplicationWindows
        case .allApplicationWindows:
            return .focusedWindow
        }
    }
}
