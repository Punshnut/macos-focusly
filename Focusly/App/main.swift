import AppKit
import Combine

/// AppKit delegate that wires together the coordinator, menus, and optional debug tooling.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var appCoordinator: FocuslyAppCoordinator?
    private var overlayController: OverlayController?
    private var localizationSubscription: AnyCancellable?
    private lazy var appIconImage = Self.loadAppIcon()

    private let accessibilityWindowTracker = WindowTracker()
    private var windowTrackerObserver: NSObjectProtocol?
    private var debugTrackingWindow: NSWindow?
    private var debugHUDWindow: NSWindow?
    private var debugHUDLabel: NSTextField?
    private var debugHUDObserver: NSObjectProtocol?
    @MainActor
    /// Performs initial setup, prompts for accessibility, and starts the coordinator.
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()

        if let appIconImage {
            NSApp.applicationIconImage = appIconImage
        }

        // Do not re-prompt on every launch when users already handled (or dismissed) the dialog.
        maybePromptForAccessibilityPermission()

        startAppCoordinator()

        if shouldDisplayDebugWindow {
            displayDebugWindow()
        }
        if shouldDisplayDebugHUD {
            displayDebugHUD()
        }

        let localizationService = LocalizationService.shared

        localizationSubscription = localizationService.$languageOverrideIdentifier
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.configureMainMenu()
            }
    }

    @MainActor
    /// Stops services before the process exits.
    func applicationWillTerminate(_ notification: Notification) {
        appCoordinator?.stop()
        dismissDebugWindow()
        dismissDebugHUD()
    }

    /// Keeps the menu bar app running after closing auxiliary windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Coordinator

    @MainActor
    /// Lazily creates the app coordinator and starts overlay management.
    private func startAppCoordinator() {
        guard appCoordinator == nil else { return }
        let environment = FocuslyEnvironment.default
        let overlayController = overlayController ?? OverlayController()
        self.overlayController = overlayController
        let coordinator = FocuslyAppCoordinator(environment: environment, overlayCoordinator: overlayController)
        self.appCoordinator = coordinator
        coordinator.start()
    }

    /// Requests Accessibility only when not granted and the last prompt is stale.
    private func maybePromptForAccessibilityPermission() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "Focusly.AutoPromptPermissions") else { return }
        guard !isAccessibilityAccessGranted() else { return }
        let now = Date()
        let cooldown: TimeInterval = 7 * 24 * 60 * 60
        let key = "Focusly.LastAccessibilityPromptAt"
        let lastPrompt = defaults.object(forKey: key) as? Date ?? .distantPast
        guard now.timeIntervalSince(lastPrompt) >= cooldown else { return }
        defaults.set(now, forKey: key)
        _ = requestAccessibilityIfNeeded(prompt: true)
    }

    // MARK: - Debug Window

    /// Determines whether the developer-focused debug window should be shown.
    private var shouldDisplayDebugWindow: Bool {
        ProcessInfo.processInfo.environment["FOCUSLY_DEBUG_WINDOW"] == "1" ||
        UserDefaults.standard.bool(forKey: "FocuslyDebugWindow")
    }

    private var shouldDisplayDebugHUD: Bool {
        ProcessInfo.processInfo.environment["FOCUSLY_DEBUG_HUD"] == "1" ||
        UserDefaults.standard.bool(forKey: "FocuslyDebugHUD")
    }

    @MainActor
    /// Builds and presents the debug overlay window used during development.
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

    @MainActor
    /// Tears down debug tracking and closes the debug window.
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

    /// Builds and presents the floating debug HUD that streams overlay diagnostics.
    @MainActor
    private func displayDebugHUD() {
        guard debugHUDWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 420, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85)
        window.title = "Focusly Debug HUD"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let label = NSTextField(labelWithString: "Waiting for overlay metrics…")
        label.frame = NSRect(x: 16, y: 16, width: 388, height: 88)
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 5
        window.contentView?.addSubview(label)

        debugHUDLabel = label
        debugHUDWindow = window
        window.orderFrontRegardless()

        debugHUDObserver = NotificationCenter.default.addObserver(
            forName: OverlayController.debugHUDDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let mode = notification.userInfo?["mode"] as? String ?? "unknown"
            let lastUpdate = notification.userInfo?["lastUpdateISO8601"] as? String ?? "n/a"
            let cacheHitRate = notification.userInfo?["cacheHitRate"] as? Double ?? 0
            let eventRate = notification.userInfo?["eventRate"] as? Double ?? 0
            let reason = notification.userInfo?["lastFallbackReason"] as? String ?? "none"
            DispatchQueue.main.async { [weak self] in
                self?.debugHUDLabel?.stringValue =
                """
                mode: \(mode)
                lastUpdate: \(lastUpdate)
                cacheHitRate: \(String(format: "%.2f", cacheHitRate))%
                eventRate: \(String(format: "%.2f", eventRate))/s
                lastFallbackReason: \(reason)
                """
            }
        }
    }

    /// Dismisses the debug HUD and unregisters its notification observer.
    @MainActor
    private func dismissDebugHUD() {
        if let debugHUDObserver {
            NotificationCenter.default.removeObserver(debugHUDObserver)
            self.debugHUDObserver = nil
        }
        debugHUDWindow?.orderOut(nil)
        debugHUDWindow = nil
        debugHUDLabel = nil
    }

    @MainActor
    /// Updates the debug window title with the latest focused window geometry.
    private func renderDebugSnapshot(_ snapshot: WindowTracker.Snapshot) {
        guard let window = debugTrackingWindow else { return }
        if let frame = snapshot.activeFrame {
            window.title = "Focusly – Active: x:\(Int(frame.origin.x)) y:\(Int(frame.origin.y)) w:\(Int(frame.size.width)) h:\(Int(frame.size.height))"
        } else {
            window.title = "Focusly – Active: (none)"
        }
    }

    @MainActor
    /// Clears debug resources if the debug window is manually closed.
    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }
        if closedWindow === debugTrackingWindow {
            dismissDebugWindow()
        }
        if closedWindow === debugHUDWindow {
            dismissDebugHUD()
        }
    }

    // MARK: - Menu

    @MainActor
    /// Rebuilds the app-level menu with localized titles and actions.
    private func configureMainMenu() {
        let localizationService = LocalizationService.shared
        let applicationMenu = NSMenu()
        let applicationMenuItem = NSMenuItem()
        let applicationSubmenu = NSMenu()

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Focusly"

        let quitMenuTemplate = localizationService.localized(
            "AppQuitMenuItemFormat",
            fallback: "AppQuitMenuItemFormat"
        )
        let quitMenuTitle = String(format: quitMenuTemplate, locale: localizationService.locale, appName)
        let quitMenuItem = NSMenuItem(title: quitMenuTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitMenuItem.target = nil
        applicationSubmenu.addItem(quitMenuItem)

        applicationMenu.addItem(applicationMenuItem)
        applicationMenu.setSubmenu(applicationSubmenu, for: applicationMenuItem)

        NSApp.mainMenu = applicationMenu
    }

}

private extension AppDelegate {
    /// Loads the bundled Focusly icon for use in menus and app surfaces.
    static func loadAppIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "Focusly", withExtension: "icon"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        return image
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory) // Hide Dock icon while keeping status item active.
application.run()
