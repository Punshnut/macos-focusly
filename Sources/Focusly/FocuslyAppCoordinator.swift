import AppKit
import Combine

/// Central coordinator responsible for wiring together overlays, preferences, onboarding, and status bar state.
@MainActor
final class FocuslyAppCoordinator: NSObject {
    private enum UserDefaultsKey {
        static let overlaysEnabled = "Focusly.Enabled"
        static let hotkeysEnabled = "Focusly.HotkeysEnabled"
        static let shortcut = "Focusly.Shortcut"
        static let onboardingCompleted = "Focusly.OnboardingCompleted"
        static let statusIconStyle = "Focusly.StatusIconStyle"
        static let languageOverride = "Focusly.LanguageOverride"
    }

    private let appEnvironment: FocuslyEnvironment
    private let appSettings: AppSettings
    private let profileStore: ProfileStore
    private let overlayWindowService: OverlayService
    private let overlayController: OverlayController
    private let statusBarController: StatusBarController
    private let hotkeyManager: HotkeyCenter
    private var onboardingWindowController: OnboardingWindowController? // Retain the welcome flow while it is onscreen.
    private let localizationService: LocalizationService
    private var localizationSubscription: AnyCancellable?

    private var preferencesWindowController: PreferencesWindowController?
    private var preferencesViewModel: PreferencesViewModel?
    private var displayChangeObserver: NSObjectProtocol?
    private var spaceChangeObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var lastActivatedNonSelfPID: pid_t?

    private var areOverlaysEnabled: Bool {
        didSet { persistOverlayActivation() }
    }
    private var areHotkeysEnabled: Bool {
        didSet { persistHotkeyActivationState() }
    }
    private var activationShortcut: HotkeyShortcut? {
        didSet { persistHotkeyShortcut() }
    }
    private var statusBarIconStyle: StatusBarIconStyle {
        didSet { persistStatusIconStyle() }
    }

    // MARK: - Initialization

    /// Wires up all runtime services and restores persisted state for a new app session.
    init(environment: FocuslyEnvironment, overlayController: OverlayController) {
        self.appEnvironment = environment
        self.appSettings = AppSettings()
        self.profileStore = ProfileStore(userDefaults: environment.userDefaults)
        self.overlayWindowService = OverlayService(profileStore: profileStore, appSettings: appSettings)
        self.overlayController = overlayController
        self.localizationService = LocalizationService.shared
        self.statusBarController = StatusBarController(localization: localizationService)
        self.hotkeyManager = HotkeyCenter()

        let defaults = appEnvironment.userDefaults
        areOverlaysEnabled = defaults.object(forKey: UserDefaultsKey.overlaysEnabled) as? Bool ?? true
        areHotkeysEnabled = defaults.object(forKey: UserDefaultsKey.hotkeysEnabled) as? Bool ?? true
        activationShortcut = FocuslyAppCoordinator.loadHotkeyShortcut(from: defaults)
        if let storedStyle = defaults.string(forKey: UserDefaultsKey.statusIconStyle),
           let decoded = StatusBarIconStyle(rawValue: storedStyle) {
            statusBarIconStyle = decoded
        } else {
            statusBarIconStyle = .dot
        }

        appSettings.areFiltersEnabled = areOverlaysEnabled
        if let storedLanguage = defaults.string(forKey: UserDefaultsKey.languageOverride) {
            localizationService.languageOverrideIdentifier = storedLanguage
        }

        super.init()

        observeApplicationActivation()
        overlayWindowService.delegate = overlayController
        statusBarController.setDelegate(self)
        hotkeyManager.onActivation = { [weak self] in
            self?.toggleOverlayActivation()
        }
        hotkeyManager.updateShortcut(activationShortcut)
        hotkeyManager.setEnabled(areHotkeysEnabled && activationShortcut != nil)

        localizationSubscription = localizationService.$languageOverrideIdentifier
            .sink { [weak self] value in
                guard let self else { return }
                self.persistLanguageOverride(value)
                self.synchronizeLocalization()
            }
    }

    // MARK: - Lifecycle

    /// Starts long-lived services and brings overlays on screen if the feature is enabled.
    func start() {
        synchronizeOverlayControllerRunningState()
        overlayWindowService.setActive(areOverlaysEnabled, animated: false)
        observeDisplayChanges()
        synchronizeStatusBar()
        presentOnboardingIfNeeded()
    }

    /// Tears down observers before the app exits.
    func stop() {
        if let displayChangeObserver {
            appEnvironment.notificationCenter.removeObserver(displayChangeObserver)
        }
        if let spaceChangeObserver {
            appEnvironment.workspace.notificationCenter.removeObserver(spaceChangeObserver)
        }
        if let appActivationObserver {
            appEnvironment.workspace.notificationCenter.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    // MARK: - Display Coordination

    /// Monitors screen configuration changes to keep overlays in sync with connected displays and spaces.
    private func observeDisplayChanges() {
        displayChangeObserver = appEnvironment.notificationCenter.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.overlayWindowService.refreshDisplays(animated: true)
                self.synchronizePreferencesDisplays()
            }
        }

        spaceChangeObserver = appEnvironment.workspace.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.overlayWindowService.refreshDisplays(animated: true)
            }
        }
    }

    // MARK: - Overlay Configuration

    /// Convenience toggle invoked from the menu bar and hotkey handlers.
    private func toggleOverlayActivation() {
        setOverlayActivation(!areOverlaysEnabled)
    }

    /// Applies the user-selected overlay state and refreshes dependent systems.
    private func setOverlayActivation(_ isEnabled: Bool) {
        if isEnabled {
            let snapshot = resolveActiveWindowSnapshot(
                excluding: currentApplicationWindowNumbers(),
                preferredPID: lastActivatedNonSelfPID
            )
            overlayController.primeOverlayMask(with: snapshot)
        }
        areOverlaysEnabled = isEnabled
        appSettings.areFiltersEnabled = isEnabled
        synchronizeOverlayControllerRunningState()
        overlayWindowService.setActive(isEnabled, animated: true)
        synchronizeStatusBar()
    }

    /// Starts or stops the overlay controller based on the persisted enabled flag.
    private func synchronizeOverlayControllerRunningState() {
        if areOverlaysEnabled {
            overlayController.start()
            overlayController.setClickThrough(true)
        } else {
            overlayController.stop()
        }
    }

    // MARK: - Persistence

    /// Persists the overlay toggle so the preference survives relaunches.
    private func persistOverlayActivation() {
        appEnvironment.userDefaults.set(areOverlaysEnabled, forKey: UserDefaultsKey.overlaysEnabled)
    }

    /// Stores whether keyboard shortcuts should be respected.
    private func persistHotkeyActivationState() {
        appEnvironment.userDefaults.set(areHotkeysEnabled, forKey: UserDefaultsKey.hotkeysEnabled)
    }

    /// Saves the current activation shortcut, or removes it if clearing.
    private func persistHotkeyShortcut() {
        let defaults = appEnvironment.userDefaults
        if let activationShortcut {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(activationShortcut) {
                defaults.set(data, forKey: UserDefaultsKey.shortcut)
            }
        } else {
            defaults.removeObject(forKey: UserDefaultsKey.shortcut)
        }
    }

    /// Restores a previously persisted hotkey shortcut if one exists.
    private static func loadHotkeyShortcut(from defaults: UserDefaults) -> HotkeyShortcut? {
        guard let data = defaults.data(forKey: UserDefaultsKey.shortcut) else { return nil }
        return try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
    }

    /// Persists the selected status bar icon variant.
    private func persistStatusIconStyle() {
        appEnvironment.userDefaults.set(statusBarIconStyle.rawValue, forKey: UserDefaultsKey.statusIconStyle)
    }

    /// Writes the selected localization override, clearing the value when returning to system defaults.
    private func persistLanguageOverride(_ identifier: String?) {
        if let identifier {
            appEnvironment.userDefaults.set(identifier, forKey: UserDefaultsKey.languageOverride)
        } else {
            appEnvironment.userDefaults.removeObject(forKey: UserDefaultsKey.languageOverride)
        }
    }

    /// Reapplies localized strings wherever the user can see them.
    private func synchronizeLocalization() {
        synchronizeStatusBar()
        refreshOnboardingLocalizationIfNeeded()
    }

    private func refreshOnboardingLocalizationIfNeeded() {
        guard let controller = onboardingWindowController else { return }
        controller.updateLocalization(localization: localizationService)
        controller.updateSteps(makeOnboardingSteps())
    }

    // MARK: - Status Bar

    /// Pushes the latest overlay and shortcut state into the menu bar UI.
    private func synchronizeStatusBar() {
        let state = StatusBarState(
            areOverlaysEnabled: areOverlaysEnabled,
            areHotkeysEnabled: areHotkeysEnabled && activationShortcut != nil,
            hasShortcut: activationShortcut != nil,
            isLaunchAtLoginEnabled: appEnvironment.launchAtLogin.isEnabled(),
            isLaunchAtLoginAvailable: appEnvironment.launchAtLogin.isAvailable,
            launchAtLoginStatusMessage: appEnvironment.launchAtLogin.unavailableReason,
            activePresetIdentifier: profileStore.currentPreset().id,
            presetOptions: PresetLibrary.presets,
            iconStyle: statusBarIconStyle
        )
        statusBarController.update(state: state)
        preferencesViewModel?.presetOptions = state.presetOptions
        preferencesViewModel?.selectedPresetIdentifier = state.activePresetIdentifier
    }

    // MARK: - Preferences Flow

    /// Presents (or refreshes) the preferences window with current runtime data.
    private func presentPreferences() {
        if let controller = preferencesWindowController {
            controller.present()
            let isHotkeyActive = areHotkeysEnabled && activationShortcut != nil
            preferencesViewModel?.areHotkeysEnabled = isHotkeyActive
            preferencesViewModel?.isLaunchAtLoginEnabled = appEnvironment.launchAtLogin.isEnabled()
            preferencesViewModel?.isLaunchAtLoginAvailable = appEnvironment.launchAtLogin.isAvailable
            preferencesViewModel?.launchAtLoginStatusMessage = appEnvironment.launchAtLogin.unavailableReason
            preferencesViewModel?.applyShortcut(activationShortcut)
            preferencesViewModel?.statusIconStyle = statusBarIconStyle
            preferencesViewModel?.presetOptions = PresetLibrary.presets
            preferencesViewModel?.selectedPresetIdentifier = profileStore.currentPreset().id
            controller.updateLocalization(localization: localizationService)
            synchronizePreferencesDisplays()
            return
        }

        let viewModel = PreferencesViewModel(
            displaySettings: makeDisplaySettings(),
            areHotkeysEnabled: areHotkeysEnabled && activationShortcut != nil,
            isLaunchAtLoginEnabled: appEnvironment.launchAtLogin.isEnabled(),
            isLaunchAtLoginAvailable: appEnvironment.launchAtLogin.isAvailable,
            launchAtLoginStatusMessage: appEnvironment.launchAtLogin.unavailableReason,
            activeShortcut: activationShortcut,
            statusIconStyle: statusBarIconStyle,
            iconStyleOptions: StatusBarIconStyle.allCases,
            presetOptions: PresetLibrary.presets,
            selectedPresetIdentifier: profileStore.currentPreset().id,
            handlers: PreferencesViewModel.Callbacks(
                onDisplayChange: { [weak self] displayID, style in
                    guard let self else { return }
                    self.profileStore.updateStyle(style, forDisplayID: displayID)
                    self.overlayWindowService.updateStyle(for: displayID, animated: true)
                },
                onDisplayReset: { [weak self] displayID in
                    guard let self else { return }
                    self.profileStore.resetOverride(forDisplayID: displayID)
                    self.overlayWindowService.updateStyle(for: displayID, animated: true)
                    self.synchronizePreferencesDisplays()
                },
                onRequestShortcutCapture: { [weak self] completion in
                    self?.beginShortcutCapture(completion: completion)
                },
                onUpdateShortcut: { [weak self] shortcut in
                    guard let self else { return }
                    self.activationShortcut = shortcut
                    self.hotkeyManager.updateShortcut(shortcut)
                    let isHotkeyActive = self.areHotkeysEnabled && shortcut != nil
                    self.hotkeyManager.setEnabled(isHotkeyActive)
                    self.preferencesViewModel?.areHotkeysEnabled = isHotkeyActive
                    self.preferencesViewModel?.applyShortcut(shortcut)
                    self.synchronizeStatusBar()
                },
                onToggleHotkeys: { [weak self] enabled in
                    guard let self else { return }
                    self.areHotkeysEnabled = enabled
                    let isHotkeyActive = enabled && self.activationShortcut != nil
                    self.hotkeyManager.setEnabled(isHotkeyActive)
                    self.preferencesViewModel?.areHotkeysEnabled = isHotkeyActive
                    self.synchronizeStatusBar()
                },
                onToggleLaunchAtLogin: { [weak self] enabled in
                    guard let self else { return }
                    do {
                        try self.appEnvironment.launchAtLogin.setEnabled(enabled)
                        self.preferencesViewModel?.launchAtLoginStatusMessage = self.appEnvironment.launchAtLogin.unavailableReason
                    } catch {
                        NSSound.beep()
                        self.preferencesViewModel?.launchAtLoginStatusMessage = error.localizedDescription
                    }
                    self.preferencesViewModel?.isLaunchAtLoginEnabled = self.appEnvironment.launchAtLogin.isEnabled()
                    self.preferencesViewModel?.isLaunchAtLoginAvailable = self.appEnvironment.launchAtLogin.isAvailable
                    self.synchronizeStatusBar()
                },
                onRequestOnboarding: { [weak self] in
                    self?.presentOnboarding(force: true)
                },
                onUpdateStatusIconStyle: { [weak self] style in
                    guard let self else { return }
                    self.statusBarIconStyle = style
                    self.synchronizeStatusBar()
                },
                onSelectPreset: { [weak self] preset in
                    guard let self else { return }
                    self.profileStore.selectPreset(preset)
                    self.overlayWindowService.refreshDisplays(animated: true)
                    self.synchronizeStatusBar()
                    self.synchronizePreferencesDisplays()
                },
                onSelectLanguage: { [weak self] identifier in
                    self?.localizationService.selectLanguage(id: identifier)
                }
            )
        )

        let controller = PreferencesWindowController(viewModel: viewModel, localization: localizationService)
        preferencesViewModel = viewModel
        preferencesWindowController = controller
        controller.window?.delegate = self
        controller.present()
    }

    /// Routes the shortcut capture request down to the preferences controller.
    private func beginShortcutCapture(completion: @escaping (HotkeyShortcut?) -> Void) {
        guard let controller = preferencesWindowController else { return }
        controller.beginShortcutCapture(completion: completion)
    }

    /// Keeps the display settings section in preferences synchronized with hardware updates.
    private func synchronizePreferencesDisplays() {
        preferencesViewModel?.displaySettings = makeDisplaySettings()
    }

    /// Observes frontmost app changes so we can remember the last non-Focusly PID.
    private func observeApplicationActivation() {
        let workspace = appEnvironment.workspace
        updateLastNonSelfPID(with: workspace.frontmostApplication)
        appActivationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            Task { @MainActor [weak self] in
                self?.updateLastNonSelfPID(with: app)
            }
        }
    }

    /// Stores the PID for the most recent app activation outside of Focusly.
    private func updateLastNonSelfPID(with application: NSRunningApplication?) {
        guard let application else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if application.processIdentifier != currentPID {
            lastActivatedNonSelfPID = application.processIdentifier
        }
    }

    /// Returns window numbers belonging to Focusly so we can skip them when resolving snapshots.
    private func currentApplicationWindowNumbers() -> Set<Int> {
        let windows = NSApp?.windows ?? []
        return Set(
            windows
                .map { $0.windowNumber }
                .filter { $0 != 0 }
        )
    }

    /// Builds per-display preference models combining screen metadata and stored profile overrides.
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
                tint: tintColor,
                colorTreatment: style.colorTreatment,
                blurRadius: style.blurRadius
            )
        }
        return displays.sorted { $0.name < $1.name }
    }

    // MARK: - Onboarding

    /// Automatically surfaces onboarding until the user completes it once.
    private func presentOnboardingIfNeeded() {
        let completed = appEnvironment.userDefaults.bool(forKey: UserDefaultsKey.onboardingCompleted)
        guard !completed else { return }
        presentOnboarding(force: true)
    }

    /// Builds and presents the onboarding window, optionally forcing a rerun for returning users.
    private func presentOnboarding(force: Bool = false) {
        let completed = appEnvironment.userDefaults.bool(forKey: UserDefaultsKey.onboardingCompleted)
        guard force || !completed else { return }

        if let controller = onboardingWindowController {
            controller.updateLocalization(localization: localizationService)
            controller.present()
            return
        }

        let steps = makeOnboardingSteps()

        let viewModel = OnboardingViewModel(steps: steps) { [weak self] completed in
            guard let self else { return }
            if completed {
                self.appEnvironment.userDefaults.set(true, forKey: UserDefaultsKey.onboardingCompleted)
            }
            self.onboardingWindowController?.close()
            self.onboardingWindowController = nil
        }

        let controller = OnboardingWindowController(viewModel: viewModel, localization: localizationService)
        onboardingWindowController = controller
        controller.window?.delegate = self
        controller.present()
    }

    /// Returns the localized onboarding content sequence shown to new users.
    private func makeOnboardingSteps() -> [OnboardingViewModel.Step] {
        [
            OnboardingViewModel.Step(
                id: 0,
                title: localizationService.localized(
                    "1. Switch overlays on",
                    fallback: "1. Switch overlays on"
                ),
                message: localizationService.localized(
                    "Click the Focusly status bar icon and toggle overlays for the displays you want to soften.",
                    fallback: "Click the Focusly status bar icon and toggle overlays for the displays you want to soften."
                ),
                systemImageName: "moon.fill"
            ),
            OnboardingViewModel.Step(
                id: 1,
                title: localizationService.localized(
                    "2. Pick a filter",
                    fallback: "2. Pick a filter"
                ),
                message: localizationService.localized(
                    "Open Preferences to choose opacity, tint, and one of the Focus, Warm, Colorful, or Monochrome presets per display.",
                    fallback: "Open Preferences to choose opacity, tint, and one of the Focus, Warm, Colorful, or Monochrome presets per display."
                ),
                systemImageName: "paintpalette"
            ),
            OnboardingViewModel.Step(
                id: 2,
                title: localizationService.localized(
                    "3. Set your controls",
                    fallback: "3. Set your controls"
                ),
                message: localizationService.localized(
                    "Assign a global shortcut and enable Launch at Login in Preferences so Focusly is ready whenever you are.",
                    fallback: "Assign a global shortcut and enable Launch at Login in Preferences so Focusly is ready whenever you are."
                ),
                systemImageName: "keyboard"
            )
        ]
    }
}

// MARK: - StatusBarControllerDelegate

/// Handles menu bar interactions that affect overlays, presets, and preferences.
extension FocuslyAppCoordinator: StatusBarControllerDelegate {
    func statusBarDidToggleEnabled(_ controller: StatusBarController) {
        toggleOverlayActivation()
    }

    func statusBar(_ controller: StatusBarController, selectedPreset preset: FocusPreset) {
        profileStore.selectPreset(preset)
        overlayWindowService.refreshDisplays(animated: true)
        synchronizeStatusBar()
        synchronizePreferencesDisplays()
    }

    func statusBar(_ controller: StatusBarController, didSelectIconStyle style: StatusBarIconStyle) {
        guard statusBarIconStyle != style else { return }
        statusBarIconStyle = style
        preferencesViewModel?.statusIconStyle = style
        synchronizeStatusBar()
    }

    func statusBarDidRequestPreferences(_ controller: StatusBarController) {
        presentPreferences()
    }

    func statusBarDidRequestOnboarding(_ controller: StatusBarController) {
        presentOnboarding(force: true)
    }

    func statusBarDidToggleHotkeys(_ controller: StatusBarController) {
        areHotkeysEnabled.toggle()
        hotkeyManager.setEnabled(areHotkeysEnabled && activationShortcut != nil)
        preferencesViewModel?.areHotkeysEnabled = areHotkeysEnabled && activationShortcut != nil
        synchronizeStatusBar()
    }

    func statusBarDidToggleLaunchAtLogin(_ controller: StatusBarController) {
        guard appEnvironment.launchAtLogin.isAvailable else {
            NSSound.beep()
            preferencesViewModel?.isLaunchAtLoginAvailable = false
            preferencesViewModel?.launchAtLoginStatusMessage = appEnvironment.launchAtLogin.unavailableReason
            synchronizeStatusBar()
            return
        }
        let desiredState = !appEnvironment.launchAtLogin.isEnabled()
        do {
            try appEnvironment.launchAtLogin.setEnabled(desiredState)
        } catch {
            NSSound.beep()
        }
        preferencesViewModel?.isLaunchAtLoginEnabled = appEnvironment.launchAtLogin.isEnabled()
        preferencesViewModel?.isLaunchAtLoginAvailable = appEnvironment.launchAtLogin.isAvailable
        preferencesViewModel?.launchAtLoginStatusMessage = appEnvironment.launchAtLogin.unavailableReason
        synchronizeStatusBar()
    }

    func statusBarDidRequestQuit(_ controller: StatusBarController) {
        NSApp.terminate(nil)
    }
}

// MARK: - NSWindowDelegate

/// Drops references when windows dismiss so they can be recreated later.
extension FocuslyAppCoordinator: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === preferencesWindowController?.window {
            preferencesViewModel = nil
            preferencesWindowController = nil
        }
        if let window = notification.object as? NSWindow, window === onboardingWindowController?.window {
            onboardingWindowController = nil
        }
    }
}
