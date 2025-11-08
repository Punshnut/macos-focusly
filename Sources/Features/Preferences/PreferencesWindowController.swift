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
    private var currentTab: PreferencesTab = .general
    private let tabRelay = PreferencesTabRelay()

    /// Builds the preferences window and wires up localization and layout observers.
    init(viewModel: PreferencesViewModel, localization: LocalizationService) {
        self.viewModel = viewModel
        self.localization = localization
        let preferencesView = PreferencesView(viewModel: viewModel, tabChangeRelay: tabRelay)
            .environmentObject(localization)
        let hostingController = NSHostingController(rootView: preferencesView)
        let initialScreenHeight = NSScreen.main?.visibleFrame.height ?? NSScreen.main?.frame.height ?? 900
        let layout = PreferencesWindowController.windowLayout(
            for: viewModel.displaySettings.count,
            tab: currentTab,
            availableHeight: initialScreenHeight
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: layout.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = localization.localized(
            "Focusly Preferences",
            fallback: "Focusly Preferences"
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.toolbarStyle = .unifiedCompact
        window.level = FocuslyWindowLevels.overlayBypass // Standard level ensures overlay masking recognizes the window.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = layout.minimumSize
        window.center()
        window.contentViewController = hostingController
        super.init(window: window)
        applyWindowAppearance(glassy: viewModel.preferencesWindowGlassy)
        tabRelay.handler = { [weak self] tab in
            self?.handleTabSelectionChange(tab)
        }
        tabRelay.notify(currentTab)

        viewModel.$displaySettings
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in
                self?.updateWindowSize(for: count, tab: nil)
            }
            .store(in: &subscriptions)

        localizationSubscription = localization.$languageOverrideIdentifier
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateWindowTitle()
            }

        viewModel.$preferencesWindowGlassy
            .removeDuplicates()
            .sink { [weak self] isGlassy in
                self?.applyWindowAppearance(glassy: isGlassy)
            }
            .store(in: &subscriptions)
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

    /// Programmatically activates a specific tab (e.g. when onboarding needs to highlight Screens).
    func selectTab(_ tab: PreferencesTab) {
        guard currentTab != tab else {
            tabRelay.requestSelection(tab)
            return
        }
        currentTab = tab
        tabRelay.requestSelection(tab)
        let shouldAnimate = window?.isVisible ?? false
        updateWindowSize(for: viewModel.displaySettings.count, tab: tab, animated: shouldAnimate)
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

    /// Adjusts the window dimensions to better fit the number of connected displays and active tab.
    private func updateWindowSize(for displayCount: Int, tab: PreferencesTab?, animated: Bool = true) {
        guard let window else { return }
        let activeTab = tab ?? currentTab
        let availableHeight = window.screen?.visibleFrame.height ?? window.screen?.frame.height ?? NSScreen.main?.visibleFrame.height ?? NSScreen.main?.frame.height ?? 900
        let layout = PreferencesWindowController.windowLayout(
            for: displayCount,
            tab: activeTab,
            availableHeight: availableHeight
        )
        window.contentMinSize = layout.minimumSize
        let currentSize = window.contentLayoutRect.size
        let widthDelta = abs(currentSize.width - layout.initialSize.width)
        let heightDelta = abs(currentSize.height - layout.initialSize.height)
        guard widthDelta > 0.5 || heightDelta > 0.5 else { return }
        if window.isVisible, animated {
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

    private func applyWindowAppearance(glassy: Bool) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    private func handleTabSelectionChange(_ tab: PreferencesTab) {
        currentTab = tab
        let shouldAnimate = window?.isVisible ?? false
        updateWindowSize(for: viewModel.displaySettings.count, tab: tab, animated: shouldAnimate)
    }

    /// Returns recommended window sizes tailored to the active tab and screen count.
    private static func windowLayout(
        for displayCount: Int,
        tab: PreferencesTab,
        availableHeight: CGFloat
    ) -> (initialSize: NSSize, minimumSize: NSSize) {
        let initialWidth: CGFloat
        let minimumWidth: CGFloat
        let initialHeight: CGFloat
        let minimumHeight: CGFloat
        let heightBoost = heightAdjustment(for: availableHeight)

        switch tab {
        case .general:
            initialWidth = 560
            minimumWidth = 500
            initialHeight = 540 + heightBoost
            minimumHeight = 500 + heightBoost
        case .screen:
            switch displayCount {
            case ..<2:
                initialWidth = 640
                minimumWidth = 580
                initialHeight = 600 + heightBoost
                minimumHeight = 520 + heightBoost
            case 2:
                initialWidth = 720
                minimumWidth = 640
                initialHeight = 620 + heightBoost
                minimumHeight = 540 + heightBoost
            default:
                initialWidth = 780
                minimumWidth = 680
                initialHeight = 640 + heightBoost
                minimumHeight = 560 + heightBoost
            }
        case .about:
            initialWidth = 520
            minimumWidth = 480
            initialHeight = 520 + heightBoost
            minimumHeight = 480 + heightBoost
        }

        return (
            initialSize: NSSize(width: initialWidth, height: initialHeight),
            minimumSize: NSSize(width: minimumWidth, height: minimumHeight)
        )
    }

    private static func heightAdjustment(for availableHeight: CGFloat) -> CGFloat {
        switch availableHeight {
        case ..<720:
            return 60
        case ..<900:
            return 90
        default:
            return 120
        }
    }
}
