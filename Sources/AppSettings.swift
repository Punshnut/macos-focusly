import Foundation
import Combine

/// Lightweight observable settings model that keeps global overlay preferences in sync.
final class AppSettings: ObservableObject {
    /// Indicates whether blur/tint overlays should currently be applied to each screen.
    @Published var overlayFiltersActive: Bool = false
    @Published var windowTrackingProfile: WindowTrackingProfile = .standard
}
