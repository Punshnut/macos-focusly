import AppKit
import Combine
import SwiftUI

/// Wraps the SwiftUI onboarding view in a floating NSWindow for quick access.
@MainActor
final class OnboardingWindowController: NSWindowController {
    private let viewModel: OnboardingViewModel
    private let localization: LocalizationService
    private var localizationCancellable: AnyCancellable?

    /// Creates an onboarding window bound to the supplied view model and localization service.
    init(viewModel: OnboardingViewModel, localization: LocalizationService) {
        self.viewModel = viewModel
        self.localization = localization
        let view = OnboardingView(viewModel: viewModel).environmentObject(localization)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = localization.localized(
            "Welcome to Focusly",
            fallback: "Welcome to Focusly"
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 520, height: 360)
        window.center()
        window.contentViewController = hostingController
        window.level = FocuslyWindowLevels.overlayBypass // Align styling with preferences so overlays respect positioning.
        super.init(window: window)

        localizationCancellable = localization.$languageOverrideIdentifier
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateWindowTitle()
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Brings the onboarding window to the front and activates the app.
    func present() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Applies localization updates when the user switches languages.
    func updateLocalization(localization: LocalizationService) {
        guard localization === self.localization else { return }
        updateWindowTitle()
    }

    /// Passes new onboarding steps through to the view model.
    func updateSteps(_ steps: [OnboardingViewModel.Step]) {
        viewModel.updateSteps(steps)
    }

    /// Syncs the window title with the currently selected language.
    private func updateWindowTitle() {
        guard let window else { return }
        window.title = localization.localized(
            "Welcome to Focusly",
            fallback: "Welcome to Focusly"
        )
    }
}
