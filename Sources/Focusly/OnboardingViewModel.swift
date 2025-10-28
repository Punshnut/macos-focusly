import Combine

/// Coordinates onboarding step progression and reports completion back to the caller.
@MainActor
final class OnboardingViewModel: ObservableObject {
    struct Step: Identifiable {
        let id: Int
        let title: String
        let message: String
        let systemImageName: String?
    }

    @Published private(set) var currentIndex: Int = 0
    var steps: [Step] {
        didSet {
            if currentIndex >= steps.count {
                currentIndex = max(steps.count - 1, 0)
            }
        }
    }

    private let completion: (Bool) -> Void

    init(steps: [Step], completion: @escaping (Bool) -> Void) {
        self.steps = steps
        self.completion = completion
    }

    var currentStep: Step {
        steps[currentIndex]
    }

    var isFirstStep: Bool {
        currentIndex == 0
    }

    var isLastStep: Bool {
        currentIndex == steps.count - 1
    }

    func advance() {
        guard !steps.isEmpty else {
            completion(false)
            return
        }

        if isLastStep {
            completion(true)
        } else {
            currentIndex += 1
        }
    }

    func retreat() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    func cancel() {
        completion(false)
    }

    func updateSteps(_ newSteps: [Step]) {
        let existingID: Int? = currentIndex < steps.count ? steps[currentIndex].id : nil
        steps = newSteps
        if let existingID,
           let index = newSteps.firstIndex(where: { $0.id == existingID }) {
            currentIndex = index
        } else {
            currentIndex = max(min(currentIndex, newSteps.count - 1), 0)
        }
    }
}
