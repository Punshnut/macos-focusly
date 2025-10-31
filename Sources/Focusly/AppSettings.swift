import Foundation
import Combine

/// Lightweight observable settings model that keeps global overlay preferences in sync.
final class AppSettings: ObservableObject {
    @Published var areFiltersEnabled: Bool = false
    @Published var windowTrackingProfile: WindowTrackingProfile = .standard
}
