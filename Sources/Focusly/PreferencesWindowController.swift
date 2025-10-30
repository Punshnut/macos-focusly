import AppKit
import Combine
import SwiftUI

/// Hosts the SwiftUI preferences view inside an AppKit window and handles shortcut capture.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private let viewModel: PreferencesViewModel
    private let localization: LocalizationService
    private var shortcutEventMonitor: Any?
    private var shortcutCaptureCompletion: ((HotkeyShortcut?) -> Void)?
    private var subscriptions: Set<AnyCancellable> = []
    private var localizationSubscription: AnyCancellable?

    /// Builds the preferences window and wires up localization and layout observers.
    init(viewModel: PreferencesViewModel, localization: LocalizationService) {
        self.viewModel = viewModel
        self.localization = localization
        let preferencesView = PreferencesView(viewModel: viewModel).environmentObject(localization)
        let hostingController = NSHostingController(rootView: preferencesView)
        let layout = PreferencesWindowController.windowLayout(for: viewModel.displaySettings.count)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: layout.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = localization.localized(
            "Focusly Preferences",
            fallback: "Focusly Preferences"
        )
        window.isReleasedWhenClosed = false
        window.contentMinSize = layout.minimumSize
        window.center()
        window.contentViewController = hostingController
        super.init(window: window)

        viewModel.$displaySettings
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in
                self?.updateWindowSize(for: count)
            }
            .store(in: &subscriptions)

        localizationSubscription = localization.$languageOverrideIdentifier
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateWindowTitle()
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    deinit {
        stopShortcutCapture()
    }

    /// Brings the preferences window to the foreground and focuses the app.
    func present() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Updates localized chrome when the language changes.
    func updateLocalization(localization: LocalizationService) {
        guard localization === self.localization else { return }
        updateWindowTitle()
    }

    /// Begins listening for a keyboard shortcut and reports the captured combination.
    func beginShortcutCapture(completion: @escaping (HotkeyShortcut?) -> Void) {
        shortcutCaptureCompletion = completion
        if shortcutEventMonitor != nil {
            stopShortcutCapture()
        }

        shortcutEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

            if event.keyCode == 53 { // Escape cancels
                self.shortcutCaptureCompletion?(nil)
                self.stopShortcutCapture()
                return nil
            }

            guard !modifiers.isEmpty else {
                NSSound.beep()
                return nil
            }

            let shortcut = HotkeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            self.shortcutCaptureCompletion?(shortcut)
            self.stopShortcutCapture()
            return nil
        }
    }

    /// Cleans up the local event monitor after shortcut capture completes.
    private func stopShortcutCapture() {
        if let shortcutEventMonitor {
            NSEvent.removeMonitor(shortcutEventMonitor)
        }
        shortcutEventMonitor = nil
        shortcutCaptureCompletion = nil
    }

    /// Adjusts the window dimensions to better fit the number of connected displays.
    private func updateWindowSize(for displayCount: Int) {
        guard let window else { return }
        let layout = PreferencesWindowController.windowLayout(for: displayCount)
        window.contentMinSize = layout.minimumSize
        let currentSize = window.contentLayoutRect.size
        let widthDelta = abs(currentSize.width - layout.initialSize.width)
        let heightDelta = abs(currentSize.height - layout.initialSize.height)
        guard widthDelta > 0.5 || heightDelta > 0.5 else { return }
        if window.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.setContentSize(layout.initialSize)
            }
        } else {
            window.setContentSize(layout.initialSize)
            window.center()
        }
    }

    /// Reflects the current localization in the window title.
    private func updateWindowTitle() {
        guard let window else { return }
        window.title = localization.localized(
            "Focusly Preferences",
            fallback: "Focusly Preferences"
        )
    }

    /// Returns recommended window sizes based on how many display cards will be shown.
    private static func windowLayout(for displayCount: Int) -> (initialSize: NSSize, minimumSize: NSSize) {
        let multipleDisplays = displayCount > 1
        let initialWidth: CGFloat = multipleDisplays ? 640 : 520
        let minimumWidth: CGFloat = multipleDisplays ? 560 : 460
        let initialHeight: CGFloat = 640
        let minimumHeight: CGFloat = 520
        return (
            initialSize: NSSize(width: initialWidth, height: initialHeight),
            minimumSize: NSSize(width: minimumWidth, height: minimumHeight)
        )
    }
}
