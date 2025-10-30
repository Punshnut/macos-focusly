import AppKit
import Combine

/// AppKit delegate that wires together the coordinator, menus, and optional debug tooling.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var appCoordinator: FocuslyAppCoordinator?
    private var overlayController: OverlayController?
    private var localizationSubscription: AnyCancellable?

    private let accessibilityWindowTracker = WindowTracker()
    private var windowTrackerObserver: NSObjectProtocol?
    private var debugTrackingWindow: NSWindow?
    /// Performs initial setup, prompts for accessibility, and starts the coordinator.
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()

        // Prompt for accessibility once so overlays can function after relaunch.
        _ = requestAccessibilityIfNeeded(prompt: true)

        startAppCoordinator()

        if shouldDisplayDebugWindow {
            displayDebugWindow()
        }

        let localizationService = LocalizationService.shared

        localizationSubscription = localizationService.$languageOverrideIdentifier
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.configureMainMenu()
            }
    }

    /// Stops services before the process exits.
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        appCoordinator?.stop()
        dismissDebugWindow()
    }

    /// Keeps the menu bar app running after closing auxiliary windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Coordinator

    /// Lazily creates the app coordinator and starts overlay management.
    @MainActor
    private func startAppCoordinator() {
        guard appCoordinator == nil else { return }
        let environment = FocuslyEnvironment.default
        let overlayController = overlayController ?? OverlayController()
        self.overlayController = overlayController
        let coordinator = FocuslyAppCoordinator(environment: environment, overlayController: overlayController)
        self.appCoordinator = coordinator
        coordinator.start()
    }

    // MARK: - Debug Window

    /// Determines whether the developer-focused debug window should be shown.
    private var shouldDisplayDebugWindow: Bool {
        ProcessInfo.processInfo.environment["FOCUSLY_DEBUG_WINDOW"] == "1" ||
        UserDefaults.standard.bool(forKey: "FocuslyDebugWindow")
    }

    /// Builds and presents the debug overlay window used during development.
    @MainActor
    private func displayDebugWindow() {
        guard debugTrackingWindow == nil else { return }

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

        debugTrackingWindow = window

        // Track less aggressively to avoid UI hitches when debug window is visible.
        accessibilityWindowTracker.pollingInterval = 0.5
        accessibilityWindowTracker.isCollectingAllWindows = true
        startDebugWindowTracking()
    }

    /// Hooks the window tracker to feed updates into the debug overlay.
    private func startDebugWindowTracking() {
        windowTrackerObserver = NotificationCenter.default.addObserver(
            forName: WindowTracker.didUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let snapshot = notification.object as? WindowTracker.Snapshot else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.renderDebugSnapshot(snapshot)
            }
        }
        accessibilityWindowTracker.start()
    }

    /// Tears down debug tracking and closes the debug window.
    @MainActor
    private func dismissDebugWindow() {
        accessibilityWindowTracker.stop()
        accessibilityWindowTracker.isCollectingAllWindows = false
        if let observer = windowTrackerObserver {
            NotificationCenter.default.removeObserver(observer)
            windowTrackerObserver = nil
        }
        debugTrackingWindow?.orderOut(nil)
        debugTrackingWindow = nil
    }

    /// Updates the debug window title with the latest focused window geometry.
    @MainActor
    private func renderDebugSnapshot(_ snapshot: WindowTracker.Snapshot) {
        guard let window = debugTrackingWindow else { return }
        if let frame = snapshot.activeFrame {
            window.title = "Focusly – Active: x:\(Int(frame.origin.x)) y:\(Int(frame.origin.y)) w:\(Int(frame.size.width)) h:\(Int(frame.size.height))"
        } else {
            window.title = "Focusly – Active: (none)"
        }
    }

    /// Clears debug resources if the debug window is manually closed.
    @MainActor
    func windowWillClose(_ notification: Notification) {
        guard
            let closedDebugWindow = notification.object as? NSWindow,
            closedDebugWindow === debugTrackingWindow
        else { return }
        dismissDebugWindow()
    }

    // MARK: - Menu

    /// Rebuilds the app-level menu with localized titles and actions.
    @MainActor
    private func configureMainMenu() {
        let localizationService = LocalizationService.shared
        let applicationMenu = NSMenu()
        let applicationMenuItem = NSMenuItem()
        let applicationSubmenu = NSMenu()

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Focusly"

        let aboutMenuTemplate = localizationService.localized(
            "About %@",
            fallback: "About %@"
        )
        let aboutMenuTitle = String(format: aboutMenuTemplate, locale: localizationService.locale, appName)
        let aboutMenuItem = NSMenuItem(title: aboutMenuTitle, action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        aboutMenuItem.target = self
        applicationSubmenu.addItem(aboutMenuItem)
        applicationSubmenu.addItem(NSMenuItem.separator())

        let quitMenuTemplate = localizationService.localized(
            "Quit %@",
            fallback: "Quit %@"
        )
        let quitMenuTitle = String(format: quitMenuTemplate, locale: localizationService.locale, appName)
        let quitMenuItem = NSMenuItem(title: quitMenuTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitMenuItem.target = nil
        applicationSubmenu.addItem(quitMenuItem)

        applicationMenu.addItem(applicationMenuItem)
        applicationMenu.setSubmenu(applicationSubmenu, for: applicationMenuItem)

        NSApp.mainMenu = applicationMenu
    }

    /// Shows a localized About panel with basic app metadata.
    @MainActor
    @objc private func showAboutPanel(_ sender: Any?) {
        let localizationService = LocalizationService.shared
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Focusly"
        let creditsHeader = localizationService.localized(
            "Credits",
            fallback: "Credits"
        )
        let nameLine = localizationService.localized(
            "Jan Feuerbacher",
            fallback: "Jan Feuerbacher"
        )
        let nametagLine = localizationService.localized(
            "Punshnut",
            fallback: "Punshnut"
        )

        let centeredParagraphStyle = NSMutableParagraphStyle()
        centeredParagraphStyle.alignment = .center
        let headerTextAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centeredParagraphStyle
        ]
        let bodyTextAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centeredParagraphStyle
        ]
        let credits = NSMutableAttributedString(
            string: creditsHeader + "\n",
            attributes: headerTextAttributes
        )
        let bodyText = [nameLine, nametagLine].joined(separator: "\n")
        credits.append(NSAttributedString(string: bodyText, attributes: bodyTextAttributes))

        // Placeholder icon until a dedicated About PNG is available.
        let placeholderIconSize = NSSize(width: 160, height: 160)
        let placeholderAboutIcon = NSImage(size: placeholderIconSize, flipped: false) { rect in
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
            return true
        }

        let panelOptions: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: appName,
            .credits: credits,
            .applicationIcon: placeholderAboutIcon,
            .version: FocuslyBuildInfo.marketingVersion
        ]

        NSApp.orderFrontStandardAboutPanel(options: panelOptions)
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
