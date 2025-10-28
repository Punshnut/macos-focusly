import AppKit
import Combine
import SwiftUI

/// Wraps the SwiftUI onboarding view in a floating NSWindow for quick access.
@MainActor
final class OnboardingWindowController: NSWindowController {
    private let viewModel: OnboardingViewModel
    private let localization: LocalizationService
    private var localizationCancellable: AnyCancellable?

    init(viewModel: OnboardingViewModel, localization: LocalizationService) {
        self.viewModel = viewModel
        self.localization = localization
        let view = OnboardingView(viewModel: viewModel).environmentObject(localization)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = localization.localized(
            "Welcome to Focusly",
            fallback: "Welcome to Focusly"
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = hostingController
        window.level = .floating // Keep the walkthrough visible above the overlay windows.
        super.init(window: window)

        localizationCancellable = localization.$overrideIdentifier
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateWindowTitle()
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateLocalization(localization: LocalizationService) {
        guard localization === self.localization else { return }
        updateWindowTitle()
    }

    func updateSteps(_ steps: [OnboardingViewModel.Step]) {
        viewModel.updateSteps(steps)
    }

    private func updateWindowTitle() {
        guard let window else { return }
        window.title = localization.localized(
            "Welcome to Focusly",
            fallback: "Welcome to Focusly"
        )
    }
}
