import AppKit
import SwiftUI

/// Wraps the SwiftUI onboarding view in a floating NSWindow for quick access.
@MainActor
final class OnboardingWindowController: NSWindowController {
    private let viewModel: OnboardingViewModel

    init(viewModel: OnboardingViewModel) {
        self.viewModel = viewModel
        let view = OnboardingView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString(
            "Welcome to Focusly",
            tableName: nil,
            bundle: .module,
            value: "Welcome to Focusly",
            comment: "Window title for the onboarding flow."
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = hostingController
        window.level = .floating // Keep the walkthrough visible above the overlay windows.
        super.init(window: window)
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
}
