import AppKit

@MainActor
final class FocuslyAppCoordinator: NSObject {
    private enum DefaultsKeys {
        static let overlaysEnabled = "Focusly.Enabled"
        static let hotkeysEnabled = "Focusly.HotkeysEnabled"
        static let shortcut = "Focusly.Shortcut"
        static let onboardingCompleted = "Focusly.OnboardingCompleted"
    }

    private let environment: FocuslyEnvironment
    private let profileStore: ProfileStore
    private let overlayService: OverlayService
    private let statusBar: StatusBarController
    private let hotkeyCenter: HotkeyCenter
    private var onboardingController: OnboardingWindowController? // Retain the welcome flow while it is onscreen.

    private var preferencesController: PreferencesWindowController?
    private var preferencesViewModel: PreferencesViewModel?
    private var displaysObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?

    private var overlaysEnabled: Bool {
        didSet { persistOverlaysEnabled() }
    }
    private var hotkeysEnabled: Bool {
        didSet { persistHotkeysEnabled() }
    }
    private var shortcut: HotkeyShortcut? {
        didSet { persistShortcut() }
    }

    // MARK: - Initialization

    init(environment: FocuslyEnvironment) {
        self.environment = environment
        self.profileStore = ProfileStore(defaults: environment.userDefaults)
        self.overlayService = OverlayService(profileStore: profileStore)
        self.statusBar = StatusBarController()
        self.hotkeyCenter = HotkeyCenter()

        let defaults = environment.userDefaults
        overlaysEnabled = defaults.object(forKey: DefaultsKeys.overlaysEnabled) as? Bool ?? true
        hotkeysEnabled = defaults.object(forKey: DefaultsKeys.hotkeysEnabled) as? Bool ?? true
        shortcut = FocuslyAppCoordinator.loadShortcut(from: defaults)

        super.init()

        statusBar.setDelegate(self)
        hotkeyCenter.onActivation = { [weak self] in
            self?.toggleOverlays()
        }
        hotkeyCenter.updateShortcut(shortcut)
        hotkeyCenter.setEnabled(hotkeysEnabled && shortcut != nil)
    }

    // MARK: - Lifecycle

    func start() {
        overlayService.setEnabled(overlaysEnabled)
        overlayService.refreshDisplays(animated: false)
        listenForDisplayChanges()
        syncStatusBar()
        presentOnboardingIfNeeded()
    }

    func stop() {
        if let displaysObserver {
            environment.notificationCenter.removeObserver(displaysObserver)
        }
        if let spaceObserver {
            environment.workspace.notificationCenter.removeObserver(spaceObserver)
        }
    }

    // MARK: - Display Coordination

    private func listenForDisplayChanges() {
        displaysObserver = environment.notificationCenter.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.overlayService.refreshDisplays(animated: true)
                self.syncPreferencesDisplays()
            }
        }

        spaceObserver = environment.workspace.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.overlayService.refreshDisplays(animated: true)
            }
        }
    }

    // MARK: - Overlay Configuration

    private func toggleOverlays() {
        setOverlaysEnabled(!overlaysEnabled)
    }

    private func setOverlaysEnabled(_ enabled: Bool) {
        overlaysEnabled = enabled
        overlayService.setEnabled(enabled)
        overlayService.refreshDisplays(animated: true)
        syncStatusBar()
    }

    // MARK: - Persistence

    private func persistOverlaysEnabled() {
        environment.userDefaults.set(overlaysEnabled, forKey: DefaultsKeys.overlaysEnabled)
    }

    private func persistHotkeysEnabled() {
        environment.userDefaults.set(hotkeysEnabled, forKey: DefaultsKeys.hotkeysEnabled)
    }

    private func persistShortcut() {
        let defaults = environment.userDefaults
        if let shortcut {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(shortcut) {
                defaults.set(data, forKey: DefaultsKeys.shortcut)
            }
        } else {
            defaults.removeObject(forKey: DefaultsKeys.shortcut)
        }
    }

    private static func loadShortcut(from defaults: UserDefaults) -> HotkeyShortcut? {
        guard let data = defaults.data(forKey: DefaultsKeys.shortcut) else { return nil }
        return try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
    }

    // MARK: - Status Bar

    private func syncStatusBar() {
        let state = StatusBarState(
            enabled: overlaysEnabled,
            hotkeysEnabled: hotkeysEnabled && shortcut != nil,
            hasShortcut: shortcut != nil,
            launchAtLoginEnabled: environment.launchAtLogin.isEnabled(),
            launchAtLoginAvailable: environment.launchAtLogin.isAvailable,
            launchAtLoginMessage: environment.launchAtLogin.unavailableReason,
            activePresetID: profileStore.currentPreset().id,
            presets: PresetLibrary.presets
        )
        statusBar.update(state: state)
    }

    // MARK: - Preferences Flow

    private func presentPreferences() {
        if let controller = preferencesController {
            controller.present()
            let active = hotkeysEnabled && shortcut != nil
            preferencesViewModel?.hotkeysEnabled = active
            preferencesViewModel?.launchAtLoginEnabled = environment.launchAtLogin.isEnabled()
            preferencesViewModel?.launchAtLoginAvailable = environment.launchAtLogin.isAvailable
            preferencesViewModel?.launchAtLoginMessage = environment.launchAtLogin.unavailableReason
            preferencesViewModel?.applyShortcut(shortcut)
            syncPreferencesDisplays()
            return
        }

        let viewModel = PreferencesViewModel(
            displays: makeDisplaySettings(),
            hotkeysEnabled: hotkeysEnabled && shortcut != nil,
            launchAtLoginEnabled: environment.launchAtLogin.isEnabled(),
            launchAtLoginAvailable: environment.launchAtLogin.isAvailable,
            launchAtLoginMessage: environment.launchAtLogin.unavailableReason,
            shortcut: shortcut,
            callbacks: PreferencesViewModel.Callbacks(
                onDisplayChange: { [weak self] displayID, style in
                    guard let self else { return }
                    self.profileStore.updateStyle(style, forDisplayID: displayID)
                    self.overlayService.updateStyle(for: displayID, animated: true)
                },
                onDisplayReset: { [weak self] displayID in
                    guard let self else { return }
                    self.profileStore.resetOverride(forDisplayID: displayID)
                    self.overlayService.updateStyle(for: displayID, animated: true)
                    self.syncPreferencesDisplays()
                },
                onRequestShortcutCapture: { [weak self] completion in
                    self?.beginShortcutCapture(completion: completion)
                },
                onUpdateShortcut: { [weak self] shortcut in
                    guard let self else { return }
                    self.shortcut = shortcut
                    self.hotkeyCenter.updateShortcut(shortcut)
                    let active = self.hotkeysEnabled && shortcut != nil
                    self.hotkeyCenter.setEnabled(active)
                    self.preferencesViewModel?.hotkeysEnabled = active
                    self.preferencesViewModel?.applyShortcut(shortcut)
                    self.syncStatusBar()
                },
                onToggleHotkeys: { [weak self] enabled in
                    guard let self else { return }
                    self.hotkeysEnabled = enabled
                    let active = enabled && self.shortcut != nil
                    self.hotkeyCenter.setEnabled(active)
                    self.preferencesViewModel?.hotkeysEnabled = active
                    self.syncStatusBar()
                },
                onToggleLaunchAtLogin: { [weak self] enabled in
                    guard let self else { return }
                    do {
                        try self.environment.launchAtLogin.setEnabled(enabled)
                        self.preferencesViewModel?.launchAtLoginMessage = self.environment.launchAtLogin.unavailableReason
                    } catch {
                        NSSound.beep()
                        self.preferencesViewModel?.launchAtLoginMessage = error.localizedDescription
                    }
                    self.preferencesViewModel?.launchAtLoginEnabled = self.environment.launchAtLogin.isEnabled()
                    self.preferencesViewModel?.launchAtLoginAvailable = self.environment.launchAtLogin.isAvailable
                    self.syncStatusBar()
                },
                onRequestOnboarding: { [weak self] in
                    self?.presentOnboarding(force: true)
                }
            )
        )

        let controller = PreferencesWindowController(viewModel: viewModel)
        preferencesViewModel = viewModel
        preferencesController = controller
        controller.window?.delegate = self
        controller.present()
    }

    private func beginShortcutCapture(completion: @escaping (HotkeyShortcut?) -> Void) {
        guard let controller = preferencesController else { return }
        controller.beginShortcutCapture(completion: completion)
    }

    private func syncPreferencesDisplays() {
        preferencesViewModel?.displays = makeDisplaySettings()
    }

    private func makeDisplaySettings() -> [PreferencesViewModel.DisplaySettings] {
        let displays: [PreferencesViewModel.DisplaySettings] = NSScreen.screens.compactMap { screen -> PreferencesViewModel.DisplaySettings? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = DisplayID(truncating: number)
            let style = profileStore.style(forDisplayID: displayID)
            let tintColor = style.tint.makeColor()
            let name = screen.localizedName
            return PreferencesViewModel.DisplaySettings(
                id: displayID,
                name: name,
                opacity: style.opacity,
                blurRadius: style.blurRadius,
                tint: tintColor
            )
        }
        return displays.sorted { $0.name < $1.name }
    }

    // MARK: - Onboarding

    /// Automatically surfaces onboarding until the user completes it once.
    private func presentOnboardingIfNeeded() {
        let completed = environment.userDefaults.bool(forKey: DefaultsKeys.onboardingCompleted)
        guard !completed else { return }
        presentOnboarding(force: true)
    }

    /// Builds and presents the onboarding window, optionally forcing a rerun for returning users.
    private func presentOnboarding(force: Bool = false) {
        let completed = environment.userDefaults.bool(forKey: DefaultsKeys.onboardingCompleted)
        guard force || !completed else { return }

        if let controller = onboardingController {
            controller.present()
            return
        }

        let steps = [
            OnboardingViewModel.Step(
                id: 0,
                title: NSLocalizedString(
                    "Stay in the zone",
                    tableName: nil,
                    bundle: .module,
                    value: "Stay in the zone",
                    comment: "Onboarding title for the first step."
                ),
                message: NSLocalizedString(
                    "Focusly dims your screens with a soft overlay so you can concentrate on the work that matters. Enable or disable overlays anytime from the menu bar.",
                    tableName: nil,
                    bundle: .module,
                    value: "Focusly dims your screens with a soft overlay so you can concentrate on the work that matters. Enable or disable overlays anytime from the menu bar.",
                    comment: "Onboarding message describing overlays and the status menu."
                ),
                systemImageName: "moon.fill"
            ),
            OnboardingViewModel.Step(
                id: 1,
                title: NSLocalizedString(
                    "Tailor each display",
                    tableName: nil,
                    bundle: .module,
                    value: "Tailor each display",
                    comment: "Onboarding title highlighting per-display customization."
                ),
                message: NSLocalizedString(
                    "Adjust blur, opacity, and color per display in Preferences. Create the ambiance that keeps you productive across different workspaces.",
                    tableName: nil,
                    bundle: .module,
                    value: "Adjust blur, opacity, and color per display in Preferences. Create the ambiance that keeps you productive across different workspaces.",
                    comment: "Onboarding message about customizing each display."
                ),
                systemImageName: "display.2"
            ),
            OnboardingViewModel.Step(
                id: 2,
                title: NSLocalizedString(
                    "Toggle with a shortcut",
                    tableName: nil,
                    bundle: .module,
                    value: "Toggle with a shortcut",
                    comment: "Onboarding title about keyboard shortcuts."
                ),
                message: NSLocalizedString(
                    "Record a custom keyboard shortcut to flip overlays on and off instantly. The default status bar menu also gives you quick access to all controls.",
                    tableName: nil,
                    bundle: .module,
                    value: "Record a custom keyboard shortcut to flip overlays on and off instantly. The default status bar menu also gives you quick access to all controls.",
                    comment: "Onboarding message describing how to use shortcuts and the menu."
                ),
                systemImageName: "keyboard"
            )
        ]

        let viewModel = OnboardingViewModel(steps: steps) { [weak self] completed in
            guard let self else { return }
            if completed {
                self.environment.userDefaults.set(true, forKey: DefaultsKeys.onboardingCompleted)
            }
            self.onboardingController?.close()
            self.onboardingController = nil
        }

        let controller = OnboardingWindowController(viewModel: viewModel)
        onboardingController = controller
        controller.window?.delegate = self
        controller.present()
    }
}

// MARK: - StatusBarControllerDelegate

extension FocuslyAppCoordinator: StatusBarControllerDelegate {
    func statusBarDidToggleEnabled(_ controller: StatusBarController) {
        toggleOverlays()
    }

    func statusBar(_ controller: StatusBarController, selectedPreset preset: FocusPreset) {
        profileStore.selectPreset(preset)
        overlayService.refreshDisplays(animated: true)
        syncStatusBar()
        syncPreferencesDisplays()
    }

    func statusBarDidRequestPreferences(_ controller: StatusBarController) {
        presentPreferences()
    }

    func statusBarDidRequestOnboarding(_ controller: StatusBarController) {
        presentOnboarding(force: true)
    }

    func statusBarDidToggleHotkeys(_ controller: StatusBarController) {
        hotkeysEnabled.toggle()
        hotkeyCenter.setEnabled(hotkeysEnabled && shortcut != nil)
        preferencesViewModel?.hotkeysEnabled = hotkeysEnabled && shortcut != nil
        syncStatusBar()
    }

    func statusBarDidToggleLaunchAtLogin(_ controller: StatusBarController) {
        guard environment.launchAtLogin.isAvailable else {
            NSSound.beep()
            preferencesViewModel?.launchAtLoginAvailable = false
            preferencesViewModel?.launchAtLoginMessage = environment.launchAtLogin.unavailableReason
            syncStatusBar()
            return
        }
        let desired = !environment.launchAtLogin.isEnabled()
        do {
            try environment.launchAtLogin.setEnabled(desired)
        } catch {
            NSSound.beep()
        }
        preferencesViewModel?.launchAtLoginEnabled = environment.launchAtLogin.isEnabled()
        preferencesViewModel?.launchAtLoginAvailable = environment.launchAtLogin.isAvailable
        preferencesViewModel?.launchAtLoginMessage = environment.launchAtLogin.unavailableReason
        syncStatusBar()
    }

    func statusBarDidRequestQuit(_ controller: StatusBarController) {
        NSApp.terminate(nil)
    }
}

// MARK: - NSWindowDelegate

extension FocuslyAppCoordinator: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === preferencesController?.window {
            preferencesViewModel = nil
            preferencesController = nil
        }
        if let window = notification.object as? NSWindow, window === onboardingController?.window {
            onboardingController = nil
        }
    }
}
