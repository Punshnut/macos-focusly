import AppKit
import Combine

/// Central coordinator responsible for wiring together overlays, preferences, onboarding, and status bar state.
@MainActor
final class FocuslyAppCoordinator: NSObject {
    private enum UserDefaultsKey {
        static let overlaysEnabled = "Focusly.Enabled"
        static let hotkeysEnabled = "Focusly.HotkeysEnabled"
        static let shortcut = "Focusly.Shortcut"
        static let maskingHotkeysEnabled = "Focusly.MaskHotkeysEnabled"
        static let maskingShortcut = "Focusly.MaskShortcut"
        static let onboardingCompleted = "Focusly.OnboardingCompleted"
        static let statusIconStyle = "Focusly.StatusIconStyle"
        static let languageOverride = "Focusly.LanguageOverride"
        static let trackingProfile = "Focusly.WindowTrackingProfile"
        static let preferencesWindowGlassy = "Focusly.Preferences.GlassyChrome"
        static let maskingModes = "Focusly.DisplayMaskingModes"
    }

    private let environment: FocuslyEnvironment
    private let globalSettings: AppSettings
    private let overlayProfileStore: ProfileStore
    private let overlayService: OverlayService
    private let overlayCoordinator: OverlayController
    private let statusBarController: StatusBarController
    private let hotkeyCenter: HotkeyCenter
    private var onboardingWindowController: OnboardingWindowController? // Retain the welcome flow while it is onscreen.
    private var didPresentPreferencesDuringOnboarding = false
    private let localization: LocalizationService
    private var localizationCancellable: AnyCancellable?
    private var trackingProfileCancellable: AnyCancellable?
    private var preferencesWindowAppearanceCancellable: AnyCancellable?

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
        didSet { persistHotkeyActivationState(hotkeysEnabled, key: UserDefaultsKey.hotkeysEnabled) }
    }
    private var activationHotkey: HotkeyShortcut? {
        didSet { persistHotkeyShortcut(activationHotkey, key: UserDefaultsKey.shortcut) }
    }
    private var maskingHotkeyEnabled: Bool {
        didSet { persistHotkeyActivationState(maskingHotkeyEnabled, key: UserDefaultsKey.maskingHotkeysEnabled) }
    }
    private var maskingHotkey: HotkeyShortcut? {
        didSet { persistHotkeyShortcut(maskingHotkey, key: UserDefaultsKey.maskingShortcut) }
    }
    private var statusItemIconStyle: StatusBarIconStyle {
        didSet { persistStatusIconStyle() }
    }
    private let defaultApplicationMaskingMode: ApplicationMaskingMode = .allApplicationWindows
    private var displayMaskingModes: [DisplayID: ApplicationMaskingMode]

    // MARK: - Initialization

    /// Wires up all runtime services and restores persisted state for a new app session.
    init(environment: FocuslyEnvironment, overlayCoordinator: OverlayController) {
        self.environment = environment
        ApplicationMaskingIgnoreList.configureShared(userDefaults: environment.userDefaults)
        self.globalSettings = AppSettings()
        self.overlayProfileStore = ProfileStore(userDefaults: environment.userDefaults)
        self.overlayService = OverlayService(profileStore: overlayProfileStore, appSettings: globalSettings)
        self.overlayCoordinator = overlayCoordinator
        self.localization = LocalizationService.shared
        self.statusBarController = StatusBarController(localization: localization)
        self.hotkeyCenter = HotkeyCenter()

        let defaults = environment.userDefaults
        overlayFiltersEnabled = defaults.object(forKey: UserDefaultsKey.overlaysEnabled) as? Bool ?? true
        hotkeysEnabled = defaults.object(forKey: UserDefaultsKey.hotkeysEnabled) as? Bool ?? true
        activationHotkey = FocuslyAppCoordinator.loadHotkeyShortcut(from: defaults, key: UserDefaultsKey.shortcut)
        maskingHotkeyEnabled = defaults.object(forKey: UserDefaultsKey.maskingHotkeysEnabled) as? Bool ?? true
        maskingHotkey = FocuslyAppCoordinator.loadHotkeyShortcut(from: defaults, key: UserDefaultsKey.maskingShortcut)
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
        if let storedGlassyPreference = defaults.object(forKey: UserDefaultsKey.preferencesWindowGlassy) as? Bool {
            globalSettings.preferencesWindowGlassy = storedGlassyPreference
        }
        displayMaskingModes = FocuslyAppCoordinator.loadMaskingModes(from: defaults)

        super.init()

        configureMaskingModes()
        observeApplicationActivation()
        overlayService.delegate = overlayCoordinator
        overlayCoordinator.updateTrackingProfile(globalSettings.windowTrackingProfile)
        statusBarController.setDelegate(self)
        hotkeyCenter.setHandler({ [weak self] in
            self?.toggleOverlayActivation()
        }, for: .overlayToggle)
        hotkeyCenter.setHandler({ [weak self] in
            self?.toggleMaskingModeForActiveDisplay()
        }, for: .maskingModeToggle)
        hotkeyCenter.updateShortcut(activationHotkey, for: .overlayToggle)
        hotkeyCenter.setShortcutEnabled(hotkeysEnabled && activationHotkey != nil, for: .overlayToggle)
        hotkeyCenter.updateShortcut(maskingHotkey, for: .maskingModeToggle)
        hotkeyCenter.setShortcutEnabled(maskingHotkeyEnabled && maskingHotkey != nil, for: .maskingModeToggle)

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

        preferencesWindowAppearanceCancellable = globalSettings.$preferencesWindowGlassy
            .removeDuplicates()
            .sink { [weak self] isGlassy in
                guard let self else { return }
                self.persistPreferencesWindowAppearance(isGlassy)
                self.preferencesScreenModel?.preferencesWindowGlassy = isGlassy
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
                preferredPID: lastKnownExternalPID,
                includeAllApplicationWindows: overlayCoordinator.prefersApplicationWideMasking
            )
            overlayCoordinator.primeOverlayMask(with: snapshot)
        }
        overlayFiltersEnabled = isEnabled
        globalSettings.overlayFiltersActive = isEnabled
        synchronizeOverlayControllerRunningState()
        overlayService.setActive(isEnabled, animated: true)
        synchronizeStatusBar()
    }

    /// Seeds the overlay controller with the default and per-display masking modes.
    private func configureMaskingModes() {
        overlayCoordinator.setDefaultApplicationMaskingMode(defaultApplicationMaskingMode)
        for (displayID, mode) in displayMaskingModes {
            overlayCoordinator.setApplicationMaskingMode(mode, for: displayID)
        }
    }

    // MARK: - Masking Preferences

    private static func loadMaskingModes(from defaults: UserDefaults) -> [DisplayID: ApplicationMaskingMode] {
        guard let stored = defaults.dictionary(forKey: UserDefaultsKey.maskingModes) as? [String: String] else {
            return [:]
        }

        var decoded: [DisplayID: ApplicationMaskingMode] = [:]
        for (key, value) in stored {
            guard
                let rawIdentifier = UInt32(key, radix: 10),
                let mode = ApplicationMaskingMode(rawValue: value)
            else {
                continue
            }
            decoded[DisplayID(rawIdentifier)] = mode
        }
        return decoded
    }

    private func persistMaskingModes() {
        let payload = displayMaskingModes.reduce(into: [String: String]()) { partialResult, entry in
            partialResult[String(entry.key)] = entry.value.rawValue
        }
        environment.userDefaults.set(payload, forKey: UserDefaultsKey.maskingModes)
    }

    private func toggleMaskingMode(for displayID: DisplayID) {
        let current = displayMaskingModes[displayID] ?? defaultApplicationMaskingMode
        let updated = current.toggled
        if updated == defaultApplicationMaskingMode {
            displayMaskingModes.removeValue(forKey: displayID)
        } else {
            displayMaskingModes[displayID] = updated
        }
        persistMaskingModes()
        overlayCoordinator.setApplicationMaskingMode(updated, for: displayID)
    }

    private func toggleMaskingModeForActiveDisplay() {
        let fallbackDisplay = displayIdentifier(for: NSScreen.main) ?? displayIdentifier(for: NSScreen.screens.first)
        let resolvedDisplayID = overlayCoordinator.activeDisplayIdentifier() ?? fallbackDisplay
        guard let displayID = resolvedDisplayID else {
            NSSound.beep()
            return
        }
        toggleMaskingMode(for: displayID)
    }

    private func displayIdentifier(for screen: NSScreen?) -> DisplayID? {
        guard
            let screen,
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return nil
        }
        return DisplayID(truncating: number)
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
    private func persistHotkeyActivationState(_ isEnabled: Bool, key: String) {
        environment.userDefaults.set(isEnabled, forKey: key)
    }

    /// Saves the current activation shortcut, or removes it if clearing.
    private func persistHotkeyShortcut(_ shortcut: HotkeyShortcut?, key: String) {
        let defaults = environment.userDefaults
        if let shortcut {
            let jsonEncoder = JSONEncoder()
            if let encodedShortcut = try? jsonEncoder.encode(shortcut) {
                defaults.set(encodedShortcut, forKey: key)
            }
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Persists the selected window tracking profile.
    private func persistTrackingProfile(_ profile: WindowTrackingProfile) {
        environment.userDefaults.set(profile.rawValue, forKey: UserDefaultsKey.trackingProfile)
    }

    /// Saves the user's preferred preferences window material.
    private func persistPreferencesWindowAppearance(_ isGlassy: Bool) {
        environment.userDefaults.set(isGlassy, forKey: UserDefaultsKey.preferencesWindowGlassy)
    }

    /// Restores a previously persisted hotkey shortcut if one exists.
    private static func loadHotkeyShortcut(from defaults: UserDefaults, key: String) -> HotkeyShortcut? {
        guard let persistedData = defaults.data(forKey: key) else { return nil }
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

    /// Updates onboarding copy when the active localization changes.
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
            synchronizePreferencesWindowAnchor()
            preferencesScreenModel?.isLaunchAtLoginEnabled = environment.launchAtLogin.isEnabled()
            preferencesScreenModel?.isLaunchAtLoginAvailable = environment.launchAtLogin.isAvailable
            preferencesScreenModel?.launchAtLoginStatusMessage = environment.launchAtLogin.unavailableReason
            preferencesScreenModel?.statusIconStyle = statusItemIconStyle
            preferencesScreenModel?.presetOptions = PresetLibrary.presets
            preferencesScreenModel?.selectedPresetIdentifier = overlayProfileStore.currentPreset().id
            preferencesScreenModel?.trackingProfile = globalSettings.windowTrackingProfile
            preferencesScreenModel?.preferencesWindowGlassy = globalSettings.preferencesWindowGlassy
            let userEntries = ApplicationMaskingIgnoreList.shared.userEntries()
            let builtInEntries = ApplicationMaskingIgnoreList.shared.activeBuiltInEntries()
            preferencesScreenModel?.refreshApplicationExceptions(
                userEntries: userEntries,
                suggestedEntries: builtInEntries
            )
            preferencesScreenModel?.updateHotkeys(hotkeyStatesSnapshot())
            controller.updateLocalization(localization: localization)
            synchronizePreferencesDisplays()
            return
        }

        let viewModel = PreferencesViewModel(
            displaySettings: makeDisplaySettings(),
            isLaunchAtLoginEnabled: environment.launchAtLogin.isEnabled(),
            isLaunchAtLoginAvailable: environment.launchAtLogin.isAvailable,
            launchAtLoginStatusMessage: environment.launchAtLogin.unavailableReason,
            hotkeyStates: hotkeyStatesSnapshot(),
            statusIconStyle: statusItemIconStyle,
            iconStyleOptions: StatusBarIconStyle.allCases,
            presetOptions: PresetLibrary.presets,
            selectedPresetIdentifier: overlayProfileStore.currentPreset().id,
            trackingProfile: globalSettings.windowTrackingProfile,
            trackingProfileOptions: WindowTrackingProfile.allCases,
            preferencesWindowGlassy: globalSettings.preferencesWindowGlassy,
            applicationEntries: ApplicationMaskingIgnoreList.shared.userEntries(),
            suggestedApplicationEntries: ApplicationMaskingIgnoreList.shared.activeBuiltInEntries(),
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
                onRequestShortcutCapture: { [weak self] action, completion in
                    self?.beginShortcutCapture(action: action, completion: completion)
                },
                onUpdateShortcut: { [weak self] action, shortcut in
                    guard let self else { return }
                    switch action {
                    case .overlayToggle:
                        self.activationHotkey = shortcut
                        self.hotkeyCenter.updateShortcut(shortcut, for: .overlayToggle)
                        let isActive = self.hotkeysEnabled && shortcut != nil
                        self.hotkeyCenter.setShortcutEnabled(isActive, for: .overlayToggle)
                    case .maskingModeToggle:
                        self.maskingHotkey = shortcut
                        self.hotkeyCenter.updateShortcut(shortcut, for: .maskingModeToggle)
                        let isActive = self.maskingHotkeyEnabled && shortcut != nil
                        self.hotkeyCenter.setShortcutEnabled(isActive, for: .maskingModeToggle)
                    }
                    self.preferencesScreenModel?.updateHotkeyState(
                        PreferencesViewModel.HotkeyState(shortcut: shortcut, isEnabled: self.hotkeyToggleValue(for: action)),
                        for: action
                    )
                    self.synchronizeStatusBar()
                },
                onToggleHotkeys: { [weak self] action, enabled in
                    guard let self else { return }
                    switch action {
                    case .overlayToggle:
                        self.hotkeysEnabled = enabled
                        let isActive = enabled && self.activationHotkey != nil
                        self.hotkeyCenter.setShortcutEnabled(isActive, for: .overlayToggle)
                    case .maskingModeToggle:
                        self.maskingHotkeyEnabled = enabled
                        let isActive = enabled && self.maskingHotkey != nil
                        self.hotkeyCenter.setShortcutEnabled(isActive, for: .maskingModeToggle)
                    }
                    self.preferencesScreenModel?.updateHotkeyState(
                        PreferencesViewModel.HotkeyState(shortcut: self.shortcut(for: action), isEnabled: enabled),
                        for: action
                    )
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
                },
                onTogglePreferencesWindowGlassy: { [weak self] isGlassy in
                    self?.globalSettings.preferencesWindowGlassy = isGlassy
                },
                onUpdateApplicationException: { entry in
                    ApplicationMaskingIgnoreList.shared.setPreference(entry.preference, bundleIdentifier: entry.bundleIdentifier)
                },
                onRemoveApplicationExceptions: { identifiers in
                    identifiers.forEach { ApplicationMaskingIgnoreList.shared.removeEntry(bundleIdentifier: $0) }
                }
            )
        )

        let controller = PreferencesWindowController(viewModel: viewModel, localization: localization)
        preferencesScreenModel = viewModel
        preferencesWindow = controller
        synchronizePreferencesWindowAnchor()
        controller.window?.delegate = self
        controller.present()
    }

    private func synchronizePreferencesWindowAnchor() {
        let anchor: PreferencesWindowController.ResizeAnchor = didPresentPreferencesDuringOnboarding ? .topLeading : .topCenter
        preferencesWindow?.setResizeAnchor(anchor)
    }

    /// Routes the shortcut capture request down to the preferences controller.
    private func beginShortcutCapture(action: HotkeyAction, completion: @escaping (HotkeyShortcut?) -> Void) {
        guard let controller = preferencesWindow else { return }
        controller.beginShortcutCapture(completion: completion)
    }

    /// Keeps the display settings section in preferences synchronized with hardware updates.
    private func synchronizePreferencesDisplays() {
        preferencesScreenModel?.displaySettings = makeDisplaySettings()
    }

    /// Captures the current shortcut assignments for the preferences UI.
    private func hotkeyStatesSnapshot() -> [HotkeyAction: PreferencesViewModel.HotkeyState] {
        [
            .overlayToggle: PreferencesViewModel.HotkeyState(shortcut: activationHotkey, isEnabled: hotkeysEnabled),
            .maskingModeToggle: PreferencesViewModel.HotkeyState(shortcut: maskingHotkey, isEnabled: maskingHotkeyEnabled)
        ]
    }

    private func shortcut(for action: HotkeyAction) -> HotkeyShortcut? {
        switch action {
        case .overlayToggle:
            return activationHotkey
        case .maskingModeToggle:
            return maskingHotkey
        }
    }

    private func hotkeyToggleValue(for action: HotkeyAction) -> Bool {
        switch action {
        case .overlayToggle:
            return hotkeysEnabled
        case .maskingModeToggle:
            return maskingHotkeyEnabled
        }
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
        if application.processIdentifier != currentPID,
           !ApplicationMaskingIgnoreList.shared.shouldIgnore(
               bundleIdentifier: application.bundleIdentifier,
               processName: application.localizedName
           ) {
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
        didPresentPreferencesDuringOnboarding = false
        synchronizePreferencesWindowAnchor()

        let viewModel = OnboardingViewModel(steps: steps) { [weak self] completed in
            guard let self else { return }
            if completed {
                self.environment.userDefaults.set(true, forKey: UserDefaultsKey.onboardingCompleted)
            }
            self.onboardingWindowController?.close()
            self.onboardingWindowController = nil
            self.didPresentPreferencesDuringOnboarding = false
            self.synchronizePreferencesWindowAnchor()
        }
        viewModel.stepChangeHandler = { [weak self] step in
            self?.handleOnboardingStepChange(step: step)
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
                    "Onboarding.Welcome.Step.Title",
                    fallback: "Welcome to Focusly"
                ),
                message: localization.localized(
                    "Onboarding.Welcome.Step.Message",
                    fallback: "Focusly ships with two settings windows: the quick status bar menu for fast toggles and the glassy Preferences window for deep, per-display tweaks. When you move to the next card we'll pop Preferences beside this dialogue so you can explore both together."
                ),
                systemImageName: "sparkles.rectangle.stack"
            ),
            OnboardingViewModel.Step(
                id: 1,
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
                id: 2,
                title: localization.localized(
                    "2. Shift-click for focus",
                    fallback: "2. Shift-click for focus"
                ),
                message: localization.localized(
                    "Shift-click the status bar icon to cycle between masking only the active window or every window from the foreground app. Each display remembers its own mode.",
                    fallback: "Shift-click the status bar icon to cycle between masking only the active window or every window from the foreground app. Each display remembers its own mode."
                ),
                systemImageName: "square.split.2x2"
            ),
            OnboardingViewModel.Step(
                id: 3,
                title: localization.localized(
                    "3. Pick a filter",
                    fallback: "3. Pick a filter"
                ),
                message: localization.localized(
                    "Open Preferences to choose opacity, tint, and one of the Focus, Warm, Ocean, or Monochrome presets per display.",
                    fallback: "Open Preferences to choose opacity, tint, and one of the Focus, Warm, Ocean, or Monochrome presets per display."
                ),
                systemImageName: "paintpalette"
            ),
            OnboardingViewModel.Step(
                id: 4,
                title: localization.localized(
                    "4. Set your controls",
                    fallback: "4. Set your controls"
                ),
                message: localization.localized(
                    "Assign a global shortcut and enable Launch at Login in Preferences so Focusly is ready whenever you are.",
                    fallback: "Assign a global shortcut and enable Launch at Login in Preferences so Focusly is ready whenever you are."
                ),
                systemImageName: "keyboard"
            )
        ]
    }

    /// Reacts to onboarding pagination so Preferences only appears once users reach key cards.
    private func handleOnboardingStepChange(step: OnboardingViewModel.Step) {
        switch step.id {
        case 1: // Card 2: introduce overlays + open Preferences window.
            guard !didPresentPreferencesDuringOnboarding else { return }
            didPresentPreferencesDuringOnboarding = true
            synchronizePreferencesWindowAnchor()
            presentPreferencesAlongsideOnboarding(anchorWindow: onboardingWindowController?.window)
        case 3: // Card 4: focus the Screen tab inside Preferences.
            if preferencesWindow == nil {
                presentPreferencesAlongsideOnboarding(anchorWindow: onboardingWindowController?.window)
            }
            preferencesWindow?.selectTab(.screen)
        case 4: // Card 5: return to the General tab to introduce hotkeys.
            if preferencesWindow == nil {
                presentPreferencesAlongsideOnboarding(anchorWindow: onboardingWindowController?.window)
            }
            preferencesWindow?.selectTab(.general)
        default:
            break
        }
    }

    /// Opens a Preferences window next to the onboarding card to mirror the requested layout.
    private func presentPreferencesAlongsideOnboarding(anchorWindow: NSWindow?) {
        guard let anchorWindow else { return }
        presentPreferences()
        guard let preferencesWindow = preferencesWindow?.window else { return }
        position(preferencesWindow, beside: anchorWindow)
    }

    private func position(_ window: NSWindow, beside anchor: NSWindow) {
        let spacing: CGFloat = 24
        var anchorFrame = anchor.frame
        let preferencesFrame = window.frame
        guard let screenFrame = anchor.screen?.visibleFrame
                ?? window.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame else {
            let origin = NSPoint(
                x: anchorFrame.maxX + spacing,
                y: anchorFrame.maxY - preferencesFrame.height
            )
            window.setFrameOrigin(origin)
            return
        }

        let combinedWidth = anchorFrame.width + spacing + preferencesFrame.width
        var combinedOriginX = screenFrame.midX - combinedWidth / 2
        if combinedWidth >= screenFrame.width {
            combinedOriginX = screenFrame.minX
        } else {
            combinedOriginX = min(max(combinedOriginX, screenFrame.minX), screenFrame.maxX - combinedWidth)
        }

        anchorFrame.origin.x = combinedOriginX
        if anchorFrame.height >= screenFrame.height {
            anchorFrame.origin.y = screenFrame.minY
        } else {
            anchorFrame.origin.y = min(
                max(anchorFrame.origin.y, screenFrame.minY),
                screenFrame.maxY - anchorFrame.height
            )
        }
        anchor.setFrameOrigin(anchorFrame.origin)
        anchorFrame.origin = anchor.frame.origin

        var origin = NSPoint(
            x: anchorFrame.maxX + spacing,
            y: anchorFrame.maxY - preferencesFrame.height
        )

        if preferencesFrame.width >= screenFrame.width {
            origin.x = screenFrame.minX
        } else {
            origin.x = min(max(origin.x, screenFrame.minX), screenFrame.maxX - preferencesFrame.width)
        }
        if preferencesFrame.height >= screenFrame.height {
            origin.y = screenFrame.minY
        } else {
            origin.y = min(max(origin.y, screenFrame.minY), screenFrame.maxY - preferencesFrame.height)
        }

        window.setFrameOrigin(origin)
    }
}

// MARK: - StatusBarControllerDelegate

/// Handles menu bar interactions that affect overlays, presets, and preferences.
extension FocuslyAppCoordinator: StatusBarControllerDelegate {
    /// Toggles overlay visibility from the status bar switch.
    func statusBarDidToggleEnabled(_ controller: StatusBarController) {
        toggleOverlayActivation()
    }

    /// Applies the selected preset and synchronizes overlays and preferences.
    func statusBar(_ controller: StatusBarController, selectedPreset preset: FocusPreset) {
        overlayProfileStore.selectPreset(preset)
        overlayService.refreshDisplays(animated: true)
        synchronizeStatusBar()
        synchronizePreferencesDisplays()
    }

    /// Persists the chosen menu bar icon variant.
    func statusBar(_ controller: StatusBarController, didSelectIconStyle style: StatusBarIconStyle) {
        guard statusItemIconStyle != style else { return }
        statusItemIconStyle = style
        preferencesScreenModel?.statusIconStyle = style
        synchronizeStatusBar()
    }

    /// Opens the preferences window when requested from the menu bar.
    func statusBarDidRequestPreferences(_ controller: StatusBarController) {
        presentPreferences()
    }

    /// Replays the onboarding walkthrough at the user's request.
    func statusBarDidRequestOnboarding(_ controller: StatusBarController) {
        presentOnboarding(force: true)
    }

    /// Flips the global hotkey enablement flag.
    func statusBarDidToggleHotkeys(_ controller: StatusBarController) {
        hotkeysEnabled.toggle()
        let isActive = hotkeysEnabled && activationHotkey != nil
        hotkeyCenter.setShortcutEnabled(isActive, for: .overlayToggle)
        preferencesScreenModel?.updateHotkeyState(
            PreferencesViewModel.HotkeyState(shortcut: activationHotkey, isEnabled: hotkeysEnabled),
            for: .overlayToggle
        )
        synchronizeStatusBar()
    }

    /// Enables or disables launch-at-login and refreshes related UI state.
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

    /// Terminates the app when the Quit menu item is selected.
    func statusBarDidRequestQuit(_ controller: StatusBarController) {
        NSApp.terminate(nil)
    }

    /// Shift-click toggles whether a display should carve out all application windows or just the focused one.
    func statusBar(_ controller: StatusBarController, didToggleMaskingModeFor displayID: DisplayID?) {
        guard let resolvedDisplayID = displayID
                ?? displayIdentifier(for: NSScreen.main)
                ?? displayIdentifier(for: NSScreen.screens.first) else {
            NSSound.beep()
            return
        }
        toggleMaskingMode(for: resolvedDisplayID)
    }
}

// MARK: - NSWindowDelegate

/// Drops references when windows dismiss so they can be recreated later.
extension FocuslyAppCoordinator: NSWindowDelegate {
    /// Releases cached window controllers when either preferences or onboarding closes.
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === preferencesWindow?.window {
            preferencesScreenModel = nil
            preferencesWindow = nil
        }
        if let window = notification.object as? NSWindow, window === onboardingWindowController?.window {
            onboardingWindowController = nil
            didPresentPreferencesDuringOnboarding = false
            synchronizePreferencesWindowAnchor()
        }
    }
}
