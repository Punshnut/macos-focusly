import AppKit

struct StatusBarState {
    var enabled: Bool
    var hotkeysEnabled: Bool
    var hasShortcut: Bool
    var launchAtLoginEnabled: Bool
    var launchAtLoginAvailable: Bool
    var launchAtLoginMessage: String?
    var activePresetID: String
    var presets: [FocusPreset]
}

@MainActor
protocol StatusBarControllerDelegate: AnyObject {
    func statusBarDidToggleEnabled(_ controller: StatusBarController)
    func statusBar(_ controller: StatusBarController, selectedPreset preset: FocusPreset)
    func statusBarDidRequestPreferences(_ controller: StatusBarController)
    func statusBarDidToggleHotkeys(_ controller: StatusBarController)
    func statusBarDidToggleLaunchAtLogin(_ controller: StatusBarController)
    func statusBarDidRequestOnboarding(_ controller: StatusBarController)
    func statusBarDidRequestQuit(_ controller: StatusBarController)
}

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let mainMenu = NSMenu(
        title: NSLocalizedString(
            "Focusly",
            tableName: nil,
            bundle: .module,
            value: "Focusly",
            comment: "App name shown in the status bar menu."
        )
    )
    private let quickMenu = NSMenu(
        title: NSLocalizedString(
            "Quick Actions",
            tableName: nil,
            bundle: .module,
            value: "Quick Actions",
            comment: "Title for the quick actions context menu."
        )
    )
    private weak var delegate: StatusBarControllerDelegate?
    private var state = StatusBarState(
        enabled: false,
        hotkeysEnabled: false,
        hasShortcut: false,
        launchAtLoginEnabled: false,
        launchAtLoginAvailable: false,
        launchAtLoginMessage: nil,
        activePresetID: PresetLibrary.presets.first?.id ?? "focus",
        presets: PresetLibrary.presets
    )

    // MARK: - Initialization

    init(delegate: StatusBarControllerDelegate? = nil) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.delegate = delegate
        super.init()
        configureStatusItem()
    }

    // MARK: - Public API

    func setDelegate(_ delegate: StatusBarControllerDelegate) {
        self.delegate = delegate
    }

    func update(state newState: StatusBarState) {
        state = newState
        rebuildMenus()
    }

    // MARK: - Menu Construction

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = localized("Focus")
        button.target = self
        button.action = #selector(handleClick(_:))
        button.appearance = NSAppearance(named: .vibrantLight)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        mainMenu.autoenablesItems = false
        mainMenu.appearance = NSAppearance(named: .vibrantLight)
        quickMenu.autoenablesItems = false
        quickMenu.appearance = NSAppearance(named: .vibrantLight)

        rebuildMenus()
    }

    private func rebuildMenus() {
        guard let button = statusItem.button else { return }
        button.title = localized(state.enabled ? "Focus•" : "Focus")

        mainMenu.removeAllItems()
        mainMenu.addItem(makeVersionMenuItem())
        mainMenu.addItem(.separator())

        let toggleTitle = localized(state.enabled ? "Disable Overlays" : "Enable Overlays")
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleOverlay), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = state.enabled ? .on : .off
        mainMenu.addItem(toggleItem)

        mainMenu.addItem(.separator())

        let presetsTitle = localized("Presets")
        let presetsItem = NSMenuItem(title: presetsTitle, action: nil, keyEquivalent: "")
        let presetsMenu = NSMenu(title: presetsTitle)
        for preset in state.presets {
            let item = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            item.state = preset.id == state.activePresetID ? .on : .off
            presetsMenu.addItem(item)
        }
        presetsMenu.addItem(.separator())

        let preferencesTitle = localized("Preferences…")
        let customizeItem = NSMenuItem(title: preferencesTitle, action: #selector(openPreferences), keyEquivalent: "")
        customizeItem.target = self
        presetsMenu.addItem(customizeItem)
        presetsItem.submenu = presetsMenu
        mainMenu.addItem(presetsItem)

        mainMenu.addItem(.separator())

        let hotkeyTitle = localized(state.hotkeysEnabled ? "Disable Shortcut" : "Enable Shortcut")
        let hotkeyItem = NSMenuItem(title: hotkeyTitle, action: #selector(toggleHotkeys), keyEquivalent: "")
        hotkeyItem.target = self
        hotkeyItem.state = state.hotkeysEnabled ? .on : .off
        hotkeyItem.isEnabled = state.hasShortcut
        mainMenu.addItem(hotkeyItem)

        if state.launchAtLoginAvailable {
            let loginKey = state.launchAtLoginEnabled ? "Launch at Login ✅" : "Launch at Login ⬜️"
            let loginTitle = localized(loginKey)
            let loginItem = NSMenuItem(title: loginTitle, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            loginItem.target = self
            loginItem.state = state.launchAtLoginEnabled ? .on : .off
            mainMenu.addItem(loginItem)
        } else if let message = state.launchAtLoginMessage {
            let loginItem = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            loginItem.isEnabled = false
            mainMenu.addItem(loginItem)
        }

        mainMenu.addItem(.separator())

        let prefsItem = NSMenuItem(title: preferencesTitle, action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        prefsItem.keyEquivalentModifierMask = [.command] // Standard macOS shortcut for preferences.
        mainMenu.addItem(prefsItem)

        let onboardingTitle = localized("Show Introduction…")
        let onboardingItem = NSMenuItem(title: onboardingTitle, action: #selector(showOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        mainMenu.addItem(onboardingItem)

        mainMenu.addItem(.separator())

        let quitTitle = localized("Quit Focusly")
        let quitItem = NSMenuItem(title: quitTitle, action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        mainMenu.addItem(quitItem)

        rebuildQuickMenu()
    }

    private func rebuildQuickMenu() {
        quickMenu.removeAllItems()
        quickMenu.addItem(makeVersionMenuItem())
        quickMenu.addItem(.separator())

        let toggleTitle = localized(state.enabled ? "Disable Overlays" : "Enable Overlays")
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleOverlay), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = state.enabled ? .on : .off
        quickMenu.addItem(toggleItem)

        let preferencesTitle = localized("Preferences…")
        let prefsItem = NSMenuItem(title: preferencesTitle, action: #selector(openPreferences), keyEquivalent: "")
        prefsItem.target = self
        quickMenu.addItem(prefsItem)

        let onboardingTitle = localized("Show Introduction…")
        let onboardingItem = NSMenuItem(title: onboardingTitle, action: #selector(showOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        // Give users a frictionless way to relaunch onboarding after first run.
        quickMenu.addItem(onboardingItem)

        quickMenu.addItem(.separator())

        let quitTitle = localized("Quit Focusly")
        let quitItem = NSMenuItem(title: quitTitle, action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        quickMenu.addItem(quitItem)
    }

    private func makeVersionMenuItem() -> NSMenuItem {
        let title = "Focusly · \(FocuslyBuildInfo.marketingVersion)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleOverlay() {
        delegate?.statusBarDidToggleEnabled(self)
    }

    @objc private func selectPreset(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        let preset = PresetLibrary.preset(withID: id)
        delegate?.statusBar(self, selectedPreset: preset)
    }

    @objc private func toggleHotkeys() {
        delegate?.statusBarDidToggleHotkeys(self)
    }

    @objc private func toggleLaunchAtLogin() {
        delegate?.statusBarDidToggleLaunchAtLogin(self)
    }

    @objc private func openPreferences() {
        delegate?.statusBarDidRequestPreferences(self)
    }

    @objc private func showOnboarding() {
        delegate?.statusBarDidRequestOnboarding(self)
    }

    @objc private func quitApp() {
        delegate?.statusBarDidRequestQuit(self)
    }

    // MARK: - Presentation

    @objc private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            showMainMenu()
            return
        }

        switch event.type {
        case .rightMouseUp, .rightMouseDown:
            showQuickMenu(with: event)
        default:
            showMainMenu()
        }
    }

    private func showMainMenu() {
        if let button = statusItem.button {
            statusItem.menu = mainMenu
            button.performClick(nil)
            statusItem.menu = nil
        }
    }

    private func showQuickMenu(with event: NSEvent) {
        if let button = statusItem.button {
            statusItem.menu = quickMenu
            NSMenu.popUpContextMenu(quickMenu, with: event, for: button)
            statusItem.menu = nil
        }
    }

    // MARK: - Localization

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .module, value: key, comment: "")
    }
}
