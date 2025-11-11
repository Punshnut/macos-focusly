import Combine

/// Coordinates onboarding step progression and reports completion back to the caller.
@MainActor
final class OnboardingViewModel: ObservableObject {
    /// Representation of one screen in the onboarding flow.
    struct Step: Identifiable {
        let id: Int
        let title: String
        let message: String
        let systemImageName: String?
    }

    @Published private(set) var currentIndex: Int = 0 {
        didSet { notifyStepChange() }
    }
    var steps: [Step] {
        didSet {
            if currentIndex >= steps.count {
                currentIndex = max(steps.count - 1, 0)
            }
        }
    }
    var stepChangeHandler: ((Step) -> Void)?

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

    /// Moves forward to the next onboarding step or finishes the flow.
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

    /// Steps backward if a previous onboarding card exists.
    func retreat() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    /// Exits the onboarding flow without marking it as completed.
    func cancel() {
        completion(false)
    }

    /// Replaces the onboarding steps while maintaining the closest possible selection.
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

    private func notifyStepChange() {
        guard steps.indices.contains(currentIndex) else { return }
        stepChangeHandler?(steps[currentIndex])
    }
}
