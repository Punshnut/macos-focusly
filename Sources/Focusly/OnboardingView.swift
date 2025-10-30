import SwiftUI

/// Lightweight SwiftUI shell for the onboarding steps with minimal chrome.
struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Spacer()
                Button {
                    viewModel.cancel()
                } label: {
                    Text(localized("Close"))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 16) {
                if let symbol = viewModel.currentStep.systemImageName {
                    Image(systemName: symbol)
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundColor(.accentColor)
                }

                Text(viewModel.currentStep.title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(viewModel.currentStep.message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                // Dot indicators reinforce current progress without extra chrome.
                ForEach(viewModel.steps) { step in
                    Circle()
                        .fill(step.id == viewModel.currentStep.id ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.vertical, 8)

            Spacer()

            HStack(spacing: 12) {
                Button {
                    viewModel.retreat()
                } label: {
                    Text(localized("Back"))
                }
                .disabled(viewModel.isFirstStep)

                Spacer()

                Button {
                    viewModel.advance()
                } label: {
                    Text(localized(viewModel.isLastStep ? "Get Started" : "Next"))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 420, height: 320)
    }

    /// Convenience wrapper so the view can access the localization service.
    private func localized(_ key: String) -> String {
        localization.localized(key, fallback: key)
    }
}
