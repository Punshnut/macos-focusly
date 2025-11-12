import Foundation
import Combine

/// Lightweight observable settings model that keeps global overlay preferences in sync.
final class AppSettings: ObservableObject {
    /// Indicates whether blur/tint overlays should currently be applied to each screen.
    @Published var overlayFiltersActive: Bool = false
    @Published var windowTrackingProfile: WindowTrackingProfile = .standard
    /// Controls whether the preferences window should use the legacy glassy chrome.
    @Published var preferencesWindowGlassy: Bool = false
    /// Determines whether Dock/Stage Manager should clear the blur when only the desktop is focused.
    @Published var desktopPeripheralRevealEnabled: Bool = false
}
