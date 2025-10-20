import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let viewModel: PreferencesViewModel
    private var eventMonitor: Any?
    private var captureCompletion: ((HotkeyShortcut?) -> Void)?

    init(viewModel: PreferencesViewModel) {
        self.viewModel = viewModel
        let view = PreferencesView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
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
        window.center()
        window.contentViewController = hostingController
        super.init(window: window)
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
}
