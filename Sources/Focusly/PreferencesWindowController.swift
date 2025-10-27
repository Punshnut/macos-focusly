import AppKit
import Combine
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let viewModel: PreferencesViewModel
    private var eventMonitor: Any?
    private var captureCompletion: ((HotkeyShortcut?) -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    init(viewModel: PreferencesViewModel) {
        self.viewModel = viewModel
        let view = PreferencesView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: view)
        let layout = PreferencesWindowController.layout(for: viewModel.displays.count)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: layout.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString(
            "Focusly Preferences",
            tableName: nil,
            bundle: .module,
            value: "Focusly Preferences",
            comment: "Window title for the preferences window."
        )
        window.isReleasedWhenClosed = false
        window.contentMinSize = layout.minimumSize
        window.center()
        window.contentViewController = hostingController
        super.init(window: window)

        viewModel.$displays
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in
                self?.updateWindowSize(for: count)
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    deinit {
        stopShortcutCapture()
    }

    func present() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func beginShortcutCapture(completion: @escaping (HotkeyShortcut?) -> Void) {
        captureCompletion = completion
        if eventMonitor != nil {
            stopShortcutCapture()
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

            if event.keyCode == 53 { // Escape cancels
                self.captureCompletion?(nil)
                self.stopShortcutCapture()
                return nil
            }

            guard !modifiers.isEmpty else {
                NSSound.beep()
                return nil
            }

            let shortcut = HotkeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            self.captureCompletion?(shortcut)
            self.stopShortcutCapture()
            return nil
        }
    }

    private func stopShortcutCapture() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        captureCompletion = nil
    }

    private func updateWindowSize(for displayCount: Int) {
        guard let window else { return }
        let layout = PreferencesWindowController.layout(for: displayCount)
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

    private static func layout(for displayCount: Int) -> (initialSize: NSSize, minimumSize: NSSize) {
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
