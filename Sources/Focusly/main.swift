import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var coordinator: FocuslyAppCoordinator?
    private var overlayController: OverlayController?

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
        attachTracker()
    }

    private func attachTracker() {
        trackerObserver = NotificationCenter.default.addObserver(
            forName: WindowTracker.didUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let snap = note.object as? WindowTracker.Snapshot,
                let self
            else { return }
            self.renderDebug(snap: snap)
        }
        windowTracker.start()
    }

    @MainActor
    private func tearDownDebugWindow() {
        windowTracker.stop()
        if let observer = trackerObserver {
            NotificationCenter.default.removeObserver(observer)
            trackerObserver = nil
        }
        debugWindow?.orderOut(nil)
        debugWindow = nil
    }

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

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Focusly"

        let aboutTitle = String(format: NSLocalizedString(
            "About %@",
            tableName: nil,
            bundle: .main,
            value: "About %@",
            comment: "Title for the default About item in the app menu."
        ), appName)
        let aboutItem = NSMenuItem(title: aboutTitle, action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())

        let quitTitle = String(format: NSLocalizedString(
            "Quit %@",
            tableName: nil,
            bundle: .main,
            value: "Quit %@",
            comment: "Title for the default Quit item in the app menu."
        ), appName)
        let quitItem = NSMenuItem(title: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = nil
        appMenu.addItem(quitItem)

        mainMenu.addItem(appMenuItem)
        mainMenu.setSubmenu(appMenu, for: appMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAboutPanel(_ sender: Any?) {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Focusly"
        let nametag = String(format: NSLocalizedString(
            "Nametag: %@",
            tableName: nil,
            bundle: .main,
            value: "Nametag: %@",
            comment: "Label showing the creator's nametag in the About panel."
        ), "Punshnut")
        let creditsLine = String(format: NSLocalizedString(
            "Credits: %@",
            tableName: nil,
            bundle: .main,
            value: "Credits: %@",
            comment: "Label showing the credits in the About panel."
        ), "Punshnut")

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: [nametag, creditsLine].joined(separator: "\n"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )

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
