import Foundation
import Combine

final class AppSettings: ObservableObject {
    @Published var filtersEnabled: Bool = true
}
