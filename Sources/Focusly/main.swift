import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var coordinator: FocuslyAppCoordinator?
    private var overlayController: OverlayController?
    private var localizationCancellable: AnyCancellable?

    private let windowTracker = WindowTracker()
    private var trackerObserver: NSObjectProtocol?
    private var debugWindow: NSWindow?
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()

        // Prompt for accessibility once so overlays can function after relaunch.
        _ = requestAccessibilityIfNeeded(prompt: true)

        startCoordinator()

        if shouldShowDebugWindow {
            presentDebugWindow()
        }

        let localization = LocalizationService.shared

        localizationCancellable = localization.$overrideIdentifier
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.configureMainMenu()
            }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        tearDownDebugWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Coordinator

    @MainActor
    private func startCoordinator() {
        guard coordinator == nil else { return }
        let environment = FocuslyEnvironment.default
        let overlayController = overlayController ?? OverlayController()
        self.overlayController = overlayController
        let coordinator = FocuslyAppCoordinator(environment: environment, overlayController: overlayController)
        self.coordinator = coordinator
        coordinator.start()
    }

    // MARK: - Debug Window

    private var shouldShowDebugWindow: Bool {
        ProcessInfo.processInfo.environment["FOCUSLY_DEBUG_WINDOW"] == "1" ||
        UserDefaults.standard.bool(forKey: "FocuslyDebugWindow")
    }

    @MainActor
    private func presentDebugWindow() {
        guard debugWindow == nil else { return }

        let window = NSWindow(
            contentRect: NSMakeRect(120, 120, 560, 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "Focusly – AX Window Tracker"
        window.center()
        window.makeKeyAndOrderFront(nil)

        let label = NSTextField(
            labelWithString: "Focusly is tracking window frames using the Accessibility API.\nGrant Accessibility in System Settings if prompted, then relaunch."
        )
        label.frame = NSRect(x: 20, y: 20, width: 520, height: 80)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        window.contentView?.addSubview(label)

        debugWindow = window

        // Track less aggressively to avoid UI hitches when debug window is visible.
        windowTracker.interval = 0.5
        windowTracker.collectsAllWindows = true
        attachTracker()
    }

    private func attachTracker() {
        trackerObserver = NotificationCenter.default.addObserver(
            forName: WindowTracker.didUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let snap = note.object as? WindowTracker.Snapshot else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.renderDebug(snap: snap)
            }
        }
        windowTracker.start()
    }

    @MainActor
    private func tearDownDebugWindow() {
        windowTracker.stop()
        windowTracker.collectsAllWindows = false
        if let observer = trackerObserver {
            NotificationCenter.default.removeObserver(observer)
            trackerObserver = nil
        }
        debugWindow?.orderOut(nil)
        debugWindow = nil
    }

    @MainActor
    private func renderDebug(snap: WindowTracker.Snapshot) {
        guard let window = debugWindow else { return }
        if let frame = snap.activeFrame {
            window.title = "Focusly – Active: x:\(Int(frame.origin.x)) y:\(Int(frame.origin.y)) w:\(Int(frame.size.width)) h:\(Int(frame.size.height))"
        } else {
            window.title = "Focusly – Active: (none)"
        }
    }

    @MainActor
    func windowWillClose(_ notification: Notification) {
        guard
            let closedWindow = notification.object as? NSWindow,
            closedWindow === debugWindow
        else { return }
        tearDownDebugWindow()
    }

    // MARK: - Menu

    @MainActor
    private func configureMainMenu() {
        let localization = LocalizationService.shared
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Focusly"

        let aboutTemplate = localization.localized(
            "About %@",
            fallback: "About %@"
        )
        let aboutTitle = String(format: aboutTemplate, locale: localization.locale, appName)
        let aboutItem = NSMenuItem(title: aboutTitle, action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())

        let quitTemplate = localization.localized(
            "Quit %@",
            fallback: "Quit %@"
        )
        let quitTitle = String(format: quitTemplate, locale: localization.locale, appName)
        let quitItem = NSMenuItem(title: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = nil
        appMenu.addItem(quitItem)

        mainMenu.addItem(appMenuItem)
        mainMenu.setSubmenu(appMenu, for: appMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @MainActor
    @objc private func showAboutPanel(_ sender: Any?) {
        let localization = LocalizationService.shared
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Focusly"
        let creditsHeader = localization.localized(
            "Credits",
            fallback: "Credits"
        )
        let nameLine = localization.localized(
            "Jan Feuerbacher",
            fallback: "Jan Feuerbacher"
        )
        let nametagLine = localization.localized(
            "Punshnut",
            fallback: "Punshnut"
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let credits = NSMutableAttributedString(
            string: creditsHeader + "\n",
            attributes: headerAttributes
        )
        let bodyText = [nameLine, nametagLine].joined(separator: "\n")
        credits.append(NSAttributedString(string: bodyText, attributes: bodyAttributes))

        // Placeholder icon until a dedicated About PNG is available.
        let placeholderSize = NSSize(width: 160, height: 160)
        let placeholderIcon = NSImage(size: placeholderSize, flipped: false) { rect in
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
            return true
        }

        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: appName,
            .credits: credits,
            .applicationIcon: placeholderIcon,
            .version: FocuslyBuildInfo.marketingVersion
        ]

        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
