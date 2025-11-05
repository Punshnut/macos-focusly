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
        static let trackingProfile = "Focusly.WindowTrackingProfile"
    }

    private let environment: FocuslyEnvironment
    private let globalSettings: AppSettings
    private let overlayProfileStore: ProfileStore
    private let overlayService: OverlayService
    private let overlayCoordinator: OverlayController
    private let statusBarController: StatusBarController
    private let hotkeyCenter: HotkeyCenter
    private var onboardingWindowController: OnboardingWindowController? // Retain the welcome flow while it is onscreen.
    private let localization: LocalizationService
    private var localizationCancellable: AnyCancellable?
    private var trackingProfileCancellable: AnyCancellable?

    private var preferencesWindow: PreferencesWindowController?
    private var preferencesScreenModel: PreferencesViewModel?
    private var displayConfigurationObserver: NSObjectProtocol?
    private var spaceSwitchObserver: NSObjectProtocol?
    private var applicationActivationObserver: NSObjectProtocol?
    private var lastKnownExternalPID: pid_t?

    private var overlayFiltersEnabled: Bool {
        didSet { persistOverlayActivation() }
    }
    private var hotkeysEnabled: Bool {
        didSet { persistHotkeyActivationState() }
    }
    private var activationHotkey: HotkeyShortcut? {
        didSet { persistHotkeyShortcut() }
    }
    private var statusItemIconStyle: StatusBarIconStyle {
        didSet { persistStatusIconStyle() }
    }

    // MARK: - Initialization

    /// Wires up all runtime services and restores persisted state for a new app session.
    init(environment: FocuslyEnvironment, overlayCoordinator: OverlayController) {
        self.environment = environment
        self.globalSettings = AppSettings()
        self.overlayProfileStore = ProfileStore(userDefaults: environment.userDefaults)
        self.overlayService = OverlayService(overlayProfileStore: overlayProfileStore, globalSettings: globalSettings)
        self.overlayCoordinator = overlayCoordinator
        self.localization = LocalizationService.shared
        self.statusBarController = StatusBarController(localization: localization)
        self.hotkeyCenter = HotkeyCenter()

        let defaults = environment.userDefaults
        overlayFiltersEnabled = defaults.object(forKey: UserDefaultsKey.overlaysEnabled) as? Bool ?? true
        hotkeysEnabled = defaults.object(forKey: UserDefaultsKey.hotkeysEnabled) as? Bool ?? true
        activationHotkey = FocuslyAppCoordinator.loadHotkeyShortcut(from: defaults)
        if let storedStyle = defaults.string(forKey: UserDefaultsKey.statusIconStyle),
           let decoded = StatusBarIconStyle(rawValue: storedStyle) {
            statusItemIconStyle = decoded
        } else {
            statusItemIconStyle = .dot
        }

        globalSettings.overlayFiltersActive = overlayFiltersEnabled
        if let storedLanguage = defaults.string(forKey: UserDefaultsKey.languageOverride) {
            localization.languageOverrideIdentifier = storedLanguage
        }
        if let storedTrackingProfile = defaults.string(forKey: UserDefaultsKey.trackingProfile),
           let decodedProfile = WindowTrackingProfile(rawValue: storedTrackingProfile) {
            globalSettings.windowTrackingProfile = decodedProfile
        }

        super.init()

        observeApplicationActivation()
        overlayService.delegate = overlayCoordinator
        overlayCoordinator.updateTrackingProfile(globalSettings.windowTrackingProfile)
        statusBarController.setDelegate(self)
        hotkeyCenter.onActivation = { [weak self] in
            self?.toggleOverlayActivation()
        }
        hotkeyCenter.updateShortcut(activationHotkey)
        hotkeyCenter.setShortcutEnabled(hotkeysEnabled && activationHotkey != nil)

        localizationCancellable = localization.$languageOverrideIdentifier
            .sink { [weak self] languageIdentifier in
                guard let self else { return }
                self.persistLanguageOverride(languageIdentifier)
                self.synchronizeLocalization()
            }

        trackingProfileCancellable = globalSettings.$windowTrackingProfile
            .removeDuplicates()
            .sink { [weak self] profile in
                guard let self else { return }
                self.overlayCoordinator.updateTrackingProfile(profile)
                self.persistTrackingProfile(profile)
            }
    }

    // MARK: - Lifecycle

    /// Starts long-lived services and brings overlays on screen if the feature is enabled.
    func start() {
        synchronizeOverlayControllerRunningState()
        overlayService.setActive(overlayFiltersEnabled, animated: false)
        observeDisplayChanges()
        synchronizeStatusBar()
        presentOnboardingIfNeeded()
    }

    /// Tears down observers before the app exits.
    func stop() {
        if let displayConfigurationObserver {
            environment.notificationCenter.removeObserver(displayConfigurationObserver)
        }
        if let spaceSwitchObserver {
            environment.workspace.notificationCenter.removeObserver(spaceSwitchObserver)
        }
        if let applicationActivationObserver {
            environment.workspace.notificationCenter.removeObserver(applicationActivationObserver)
            self.applicationActivationObserver = nil
        }
    }

    // MARK: - Display Coordination

    /// Monitors screen configuration changes to keep overlays in sync with connected displays and spaces.
    private func observeDisplayChanges() {
        displayConfigurationObserver = environment.notificationCenter.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.overlayService.refreshDisplays(animated: true)
                self.synchronizePreferencesDisplays()
            }
        }

        spaceSwitchObserver = environment.workspace.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.overlayService.refreshDisplays(animated: true)
            }
        }
    }

    // MARK: - Overlay Configuration

    /// Convenience toggle invoked from the menu bar and hotkey handlers.
    private func toggleOverlayActivation() {
        setOverlayActivation(!overlayFiltersEnabled)
    }

    /// Applies the user-selected overlay state and refreshes dependent systems.
    private func setOverlayActivation(_ isEnabled: Bool) {
        if isEnabled {
            let snapshot = resolveActiveWindowSnapshot(
                excluding: currentApplicationWindowNumbers(),
                preferredPID: lastKnownExternalPID
            )
            overlayCoordinator.primeOverlayMask(with: snapshot)
        }
        overlayFiltersEnabled = isEnabled
        globalSettings.overlayFiltersActive = isEnabled
        synchronizeOverlayControllerRunningState()
        overlayService.setActive(isEnabled, animated: true)
        synchronizeStatusBar()
    }

    /// Starts or stops the overlay controller based on the persisted enabled flag.
    private func synchronizeOverlayControllerRunningState() {
        if overlayFiltersEnabled {
            overlayCoordinator.start()
            overlayCoordinator.setClickThrough(true)
        } else {
            overlayCoordinator.stop()
        }
    }

    // MARK: - Persistence

    /// Persists the overlay toggle so the preference survives relaunches.
    private func persistOverlayActivation() {
        environment.userDefaults.set(overlayFiltersEnabled, forKey: UserDefaultsKey.overlaysEnabled)
    }

    /// Stores whether keyboard shortcuts should be respected.
    private func persistHotkeyActivationState() {
        environment.userDefaults.set(hotkeysEnabled, forKey: UserDefaultsKey.hotkeysEnabled)
    }

    /// Saves the current activation shortcut, or removes it if clearing.
    private func persistHotkeyShortcut() {
        let defaults = environment.userDefaults
        if let activationHotkey {
            let jsonEncoder = JSONEncoder()
            if let encodedShortcut = try? jsonEncoder.encode(activationHotkey) {
                defaults.set(encodedShortcut, forKey: UserDefaultsKey.shortcut)
            }
        } else {
            defaults.removeObject(forKey: UserDefaultsKey.shortcut)
        }
    }

    /// Persists the selected window tracking profile.
    private func persistTrackingProfile(_ profile: WindowTrackingProfile) {
        environment.userDefaults.set(profile.rawValue, forKey: UserDefaultsKey.trackingProfile)
    }

    /// Restores a previously persisted hotkey shortcut if one exists.
    private static func loadHotkeyShortcut(from defaults: UserDefaults) -> HotkeyShortcut? {
        guard let persistedData = defaults.data(forKey: UserDefaultsKey.shortcut) else { return nil }
        let jsonDecoder = JSONDecoder()
        return try? jsonDecoder.decode(HotkeyShortcut.self, from: persistedData)
    }

    /// Persists the selected status bar icon variant.
    private func persistStatusIconStyle() {
        environment.userDefaults.set(statusItemIconStyle.rawValue, forKey: UserDefaultsKey.statusIconStyle)
    }

    /// Writes the selected localization override, clearing the value when returning to system defaults.
    private func persistLanguageOverride(_ identifier: String?) {
        if let identifier {
            environment.userDefaults.set(identifier, forKey: UserDefaultsKey.languageOverride)
        } else {
            environment.userDefaults.removeObject(forKey: UserDefaultsKey.languageOverride)
        }
    }

    /// Reapplies localized strings wherever the user can see them.
    private func synchronizeLocalization() {
        synchronizeStatusBar()
        refreshOnboardingLocalizationIfNeeded()
    }

    private func refreshOnboardingLocalizationIfNeeded() {
        guard let controller = onboardingWindowController else { return }
        controller.updateLocalization(localization: localization)
        controller.updateSteps(makeOnboardingSteps())
    }

    // MARK: - Status Bar

    /// Pushes the latest overlay and shortcut state into the menu bar UI.
    private func synchronizeStatusBar() {
        let state = StatusBarState(
            overlayFiltersEnabled: overlayFiltersEnabled,
            hotkeysEnabled: hotkeysEnabled && activationHotkey != nil,
            hasShortcut: activationHotkey != nil,
            isLaunchAtLoginEnabled: environment.launchAtLogin.isEnabled(),
            isLaunchAtLoginAvailable: environment.launchAtLogin.isAvailable,
            launchAtLoginStatusMessage: environment.launchAtLogin.unavailableReason,
            activePresetIdentifier: overlayProfileStore.currentPreset().id,
            presetOptions: PresetLibrary.presets,
            iconStyle: statusItemIconStyle
        )
        statusBarController.update(state: state)
        preferencesScreenModel?.presetOptions = state.presetOptions
        preferencesScreenModel?.selectedPresetIdentifier = state.activePresetIdentifier
    }

    // MARK: - Preferences Flow

    /// Presents (or refreshes) the preferences window with current runtime data.
    private func presentPreferences() {
        if let controller = preferencesWindow {
            controller.present()
            let isHotkeyActive = hotkeysEnabled && activationHotkey != nil
            preferencesScreenModel?.hotkeysEnabled = isHotkeyActive
            preferencesScreenModel?.isLaunchAtLoginEnabled = environment.launchAtLogin.isEnabled()
            preferencesScreenModel?.isLaunchAtLoginAvailable = environment.launchAtLogin.isAvailable
            preferencesScreenModel?.launchAtLoginStatusMessage = environment.launchAtLogin.unavailableReason
            preferencesScreenModel?.applyShortcut(activationHotkey)
            preferencesScreenModel?.statusIconStyle = statusItemIconStyle
            preferencesScreenModel?.presetOptions = PresetLibrary.presets
            preferencesScreenModel?.selectedPresetIdentifier = overlayProfileStore.currentPreset().id
            preferencesScreenModel?.trackingProfile = globalSettings.windowTrackingProfile
            controller.updateLocalization(localization: localization)
            synchronizePreferencesDisplays()
            return
        }

        let viewModel = PreferencesViewModel(
            displaySettings: makeDisplaySettings(),
            hotkeysEnabled: hotkeysEnabled && activationHotkey != nil,
            isLaunchAtLoginEnabled: environment.launchAtLogin.isEnabled(),
            isLaunchAtLoginAvailable: environment.launchAtLogin.isAvailable,
            launchAtLoginStatusMessage: environment.launchAtLogin.unavailableReason,
            activeShortcut: activationHotkey,
            statusIconStyle: statusItemIconStyle,
            iconStyleOptions: StatusBarIconStyle.allCases,
            presetOptions: PresetLibrary.presets,
            selectedPresetIdentifier: overlayProfileStore.currentPreset().id,
            trackingProfile: globalSettings.windowTrackingProfile,
            trackingProfileOptions: WindowTrackingProfile.allCases,
            callbacks: PreferencesViewModel.Callbacks(
                onDisplayChange: { [weak self] displayID, style in
                    guard let self else { return }
                    self.overlayProfileStore.updateStyle(style, forDisplayID: displayID)
                    self.overlayService.updateStyle(for: displayID, animated: true)
                },
                onDisplayReset: { [weak self] displayID in
                    guard let self else { return }
                    self.overlayProfileStore.resetOverride(forDisplayID: displayID)
                    self.overlayService.updateStyle(for: displayID, animated: true)
                    self.synchronizePreferencesDisplays()
                },
                onRequestShortcutCapture: { [weak self] completion in
                    self?.beginShortcutCapture(completion: completion)
                },
                onUpdateShortcut: { [weak self] shortcut in
                    guard let self else { return }
                    self.activationHotkey = shortcut
                    self.hotkeyCenter.updateShortcut(shortcut)
                    let isHotkeyActive = self.hotkeysEnabled && shortcut != nil
                    self.hotkeyCenter.setShortcutEnabled(isHotkeyActive)
                    self.preferencesScreenModel?.hotkeysEnabled = isHotkeyActive
                    self.preferencesScreenModel?.applyShortcut(shortcut)
                    self.synchronizeStatusBar()
                },
                onToggleHotkeys: { [weak self] enabled in
                    guard let self else { return }
                    self.hotkeysEnabled = enabled
                    let isHotkeyActive = enabled && self.activationHotkey != nil
                    self.hotkeyCenter.setShortcutEnabled(isHotkeyActive)
                    self.preferencesScreenModel?.hotkeysEnabled = isHotkeyActive
                    self.synchronizeStatusBar()
                },
                onToggleLaunchAtLogin: { [weak self] enabled in
                    guard let self else { return }
                    do {
                        try self.environment.launchAtLogin.setEnabled(enabled)
                        self.preferencesScreenModel?.launchAtLoginStatusMessage = self.environment.launchAtLogin.unavailableReason
                    } catch {
                        NSSound.beep()
                        self.preferencesScreenModel?.launchAtLoginStatusMessage = error.localizedDescription
                    }
                    self.preferencesScreenModel?.isLaunchAtLoginEnabled = self.environment.launchAtLogin.isEnabled()
                    self.preferencesScreenModel?.isLaunchAtLoginAvailable = self.environment.launchAtLogin.isAvailable
                    self.synchronizeStatusBar()
                },
                onRequestOnboarding: { [weak self] in
                    self?.presentOnboarding(force: true)
                },
                onUpdateStatusIconStyle: { [weak self] style in
                    guard let self else { return }
                    self.statusItemIconStyle = style
                    self.synchronizeStatusBar()
                },
                onSelectPreset: { [weak self] preset in
                    guard let self else { return }
                    self.overlayProfileStore.selectPreset(preset)
                    self.overlayService.refreshDisplays(animated: true)
                    self.synchronizeStatusBar()
                    self.synchronizePreferencesDisplays()
                },
                onSelectLanguage: { [weak self] identifier in
                    self?.localization.selectLanguage(id: identifier)
                },
                onUpdateTrackingProfile: { [weak self] profile in
                    self?.globalSettings.windowTrackingProfile = profile
                },
                onToggleDisplayExclusion: { [weak self] displayID, isExcluded in
                    guard let self else { return }
                    self.overlayProfileStore.setDisplay(displayID, excluded: isExcluded)
                    self.overlayService.refreshDisplays(animated: true)
                    self.synchronizePreferencesDisplays()
                }
            )
        )

        let controller = PreferencesWindowController(viewModel: viewModel, localization: localization)
        preferencesScreenModel = viewModel
        preferencesWindow = controller
        controller.window?.delegate = self
        controller.present()
    }

    /// Routes the shortcut capture request down to the preferences controller.
    private func beginShortcutCapture(completion: @escaping (HotkeyShortcut?) -> Void) {
        guard let controller = preferencesWindow else { return }
        controller.beginShortcutCapture(completion: completion)
    }

    /// Keeps the display settings section in preferences synchronized with hardware updates.
    private func synchronizePreferencesDisplays() {
        preferencesScreenModel?.displaySettings = makeDisplaySettings()
    }

    /// Observes frontmost app changes so we can remember the last non-Focusly PID.
    private func observeApplicationActivation() {
        let workspace = environment.workspace
        updateLastNonSelfPID(with: workspace.frontmostApplication)
        applicationActivationObserver = workspace.notificationCenter.addObserver(
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
            lastKnownExternalPID = application.processIdentifier
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
            let style = overlayProfileStore.style(forDisplayID: displayID)
            let tintColor = style.tint.makeColor()
            let name = screen.localizedName
            return PreferencesViewModel.DisplaySettings(
                id: displayID,
                name: name,
                opacity: style.opacity,
                tint: tintColor,
                colorTreatment: style.colorTreatment,
                blurMaterial: style.blurMaterial,
                blurRadius: style.blurRadius,
                isExcluded: overlayProfileStore.isDisplayExcluded(displayID)
            )
        }
        return displays.sorted { $0.name < $1.name }
    }

    // MARK: - Onboarding

    /// Automatically surfaces onboarding until the user completes it once.
    private func presentOnboardingIfNeeded() {
        let completed = environment.userDefaults.bool(forKey: UserDefaultsKey.onboardingCompleted)
        guard !completed else { return }
        presentOnboarding(force: true)
    }

    /// Builds and presents the onboarding window, optionally forcing a rerun for returning users.
    private func presentOnboarding(force: Bool = false) {
        let completed = environment.userDefaults.bool(forKey: UserDefaultsKey.onboardingCompleted)
        guard force || !completed else { return }

        if let controller = onboardingWindowController {
            controller.updateLocalization(localization: localization)
            controller.present()
            return
        }

        let steps = makeOnboardingSteps()

        let viewModel = OnboardingViewModel(steps: steps) { [weak self] completed in
            guard let self else { return }
            if completed {
                self.environment.userDefaults.set(true, forKey: UserDefaultsKey.onboardingCompleted)
            }
            self.onboardingWindowController?.close()
            self.onboardingWindowController = nil
        }

        let controller = OnboardingWindowController(viewModel: viewModel, localization: localization)
        onboardingWindowController = controller
        controller.window?.delegate = self
        controller.present()
    }

    /// Returns the localized onboarding content sequence shown to new users.
    private func makeOnboardingSteps() -> [OnboardingViewModel.Step] {
        [
            OnboardingViewModel.Step(
                id: 0,
                title: localization.localized(
                    "1. Switch overlays on",
                    fallback: "1. Switch overlays on"
                ),
                message: localization.localized(
                    "Click the Focusly status bar icon and toggle overlays for the displays you want to soften.",
                    fallback: "Click the Focusly status bar icon and toggle overlays for the displays you want to soften."
                ),
                systemImageName: "moon.fill"
            ),
            OnboardingViewModel.Step(
                id: 1,
                title: localization.localized(
                    "2. Pick a filter",
                    fallback: "2. Pick a filter"
                ),
                message: localization.localized(
                    "Open Preferences to choose opacity, tint, and one of the Focus, Warm, Colorful, or Monochrome presets per display.",
                    fallback: "Open Preferences to choose opacity, tint, and one of the Focus, Warm, Colorful, or Monochrome presets per display."
                ),
                systemImageName: "paintpalette"
            ),
            OnboardingViewModel.Step(
                id: 2,
                title: localization.localized(
                    "3. Set your controls",
                    fallback: "3. Set your controls"
                ),
                message: localization.localized(
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
        overlayProfileStore.selectPreset(preset)
        overlayService.refreshDisplays(animated: true)
        synchronizeStatusBar()
        synchronizePreferencesDisplays()
    }

    func statusBar(_ controller: StatusBarController, didSelectIconStyle style: StatusBarIconStyle) {
        guard statusItemIconStyle != style else { return }
        statusItemIconStyle = style
        preferencesScreenModel?.statusIconStyle = style
        synchronizeStatusBar()
    }

    func statusBarDidRequestPreferences(_ controller: StatusBarController) {
        presentPreferences()
    }

    func statusBarDidRequestOnboarding(_ controller: StatusBarController) {
        presentOnboarding(force: true)
    }

    func statusBarDidToggleHotkeys(_ controller: StatusBarController) {
        hotkeysEnabled.toggle()
        hotkeyCenter.setShortcutEnabled(hotkeysEnabled && activationHotkey != nil)
        preferencesScreenModel?.hotkeysEnabled = hotkeysEnabled && activationHotkey != nil
        synchronizeStatusBar()
    }

    func statusBarDidToggleLaunchAtLogin(_ controller: StatusBarController) {
        guard environment.launchAtLogin.isAvailable else {
            NSSound.beep()
            preferencesScreenModel?.isLaunchAtLoginAvailable = false
            preferencesScreenModel?.launchAtLoginStatusMessage = environment.launchAtLogin.unavailableReason
            synchronizeStatusBar()
            return
        }
        let desiredState = !environment.launchAtLogin.isEnabled()
        do {
            try environment.launchAtLogin.setEnabled(desiredState)
        } catch {
            NSSound.beep()
        }
        preferencesScreenModel?.isLaunchAtLoginEnabled = environment.launchAtLogin.isEnabled()
        preferencesScreenModel?.isLaunchAtLoginAvailable = environment.launchAtLogin.isAvailable
        preferencesScreenModel?.launchAtLoginStatusMessage = environment.launchAtLogin.unavailableReason
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
        if let window = notification.object as? NSWindow, window === preferencesWindow?.window {
            preferencesScreenModel = nil
            preferencesWindow = nil
        }
        if let window = notification.object as? NSWindow, window === onboardingWindowController?.window {
            onboardingWindowController = nil
        }
    }
}
