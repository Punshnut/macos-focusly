import AppKit
import Combine
import QuartzCore

private let applicationAppearanceNotificationName = Notification.Name("NSApplicationDidChangeEffectiveAppearanceNotification")

/// Visual styles Focusly can display in the macOS status bar.
enum StatusBarIconStyle: String, CaseIterable, Codable, Equatable, Hashable {
    case dot
    case halo
    case pulse

    /// Localized display name used for menu selections.
    @MainActor var localizedName: String {
        let localization = LocalizationService.shared
        switch self {
        case .dot:
            return localization.localized(
                "Standard Icon",
                fallback: "Standard Icon"
            )
        case .halo:
            return localization.localized(
                "Halo",
                fallback: "Halo"
            )
        case .pulse:
            return localization.localized(
                "Equalizer",
                fallback: "Equalizer"
            )
        }
    }
}

/// Snapshot of data needed to render status bar menus and tooltips.
struct StatusBarState {
    var overlayFiltersEnabled: Bool
    var hotkeysEnabled: Bool
    var hasShortcut: Bool
    var isLaunchAtLoginEnabled: Bool
    var isLaunchAtLoginAvailable: Bool
    var launchAtLoginStatusMessage: String?
    var activePresetIdentifier: String
    var presetOptions: [FocusPreset]
    var iconStyle: StatusBarIconStyle
}

/// Receives events triggered from the Focusly status bar menus.
@MainActor
protocol StatusBarControllerDelegate: AnyObject {
    /// User toggled the overlay enablement menu item.
    func statusBarDidToggleEnabled(_ controller: StatusBarController)
    /// User selected a different preset from the menu.
    func statusBar(_ controller: StatusBarController, selectedPreset preset: FocusPreset)
    /// User picked a new icon appearance for the status item.
    func statusBar(_ controller: StatusBarController, didSelectIconStyle style: StatusBarIconStyle)
    /// Preferences window should be shown.
    func statusBarDidRequestPreferences(_ controller: StatusBarController)
    /// Hotkey enablement switch was toggled.
    func statusBarDidToggleHotkeys(_ controller: StatusBarController)
    /// Launch-at-login checkbox was toggled.
    func statusBarDidToggleLaunchAtLogin(_ controller: StatusBarController)
    /// Onboarding flow should be presented again.
    func statusBarDidRequestOnboarding(_ controller: StatusBarController)
    /// App should terminate in response to the Quit menu item.
    func statusBarDidRequestQuit(_ controller: StatusBarController)
    /// Shift-click toggled whether all application windows should be carved out on a display.
    func statusBar(_ controller: StatusBarController, didToggleMaskingModeFor displayID: DisplayID?)
}

/// Builds and manages the menu bar item, including icons, menus, and hotkey shortcuts.
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let mainMenu: NSMenu
    private let quickMenu: NSMenu
    private weak var delegate: StatusBarControllerDelegate?
    private let localization: LocalizationService
    private var localizationCancellable: AnyCancellable?
    private var state = StatusBarState(
        overlayFiltersEnabled: false,
        hotkeysEnabled: false,
        hasShortcut: false,
        isLaunchAtLoginEnabled: false,
        isLaunchAtLoginAvailable: false,
        launchAtLoginStatusMessage: nil,
        activePresetIdentifier: PresetLibrary.presets.first?.id ?? "focus",
        presetOptions: PresetLibrary.presets,
        iconStyle: .dot
    )

    // MARK: - Initialization

    /// Configures the status item, menus, and observers needed to stay in sync with system appearance and localization.
    init(delegate: StatusBarControllerDelegate? = nil, localization: LocalizationService? = nil) {
        let localization = localization ?? LocalizationService.shared
        self.localization = localization
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.mainMenu = NSMenu(title: localization.localized("Focusly", fallback: "Focusly"))
        self.quickMenu = NSMenu(title: localization.localized("Quick Actions", fallback: "Quick Actions"))
        self.delegate = delegate
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChange),
            name: applicationAppearanceNotificationName,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleAppearanceChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        mainMenu.autoenablesItems = false
        mainMenu.appearance = NSAppearance(named: .vibrantLight)
        quickMenu.autoenablesItems = false
        quickMenu.appearance = NSAppearance(named: .vibrantLight)
        configureStatusItem()

        localizationCancellable = localization.$languageOverrideIdentifier
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateMenuTitles()
                self?.rebuildMenus()
            }
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: applicationAppearanceNotificationName, object: nil)
        DistributedNotificationCenter.default().removeObserver(self, name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    }

    // MARK: - Public API

    /// Assigns the delegate after initialization.
    func setDelegate(_ delegate: StatusBarControllerDelegate) {
        self.delegate = delegate
    }

    /// Applies new state from the coordinator so menus can refresh.
    func update(state newState: StatusBarState) {
        let previousState = state
        state = newState
        let overlayChanged = previousState.overlayFiltersEnabled != newState.overlayFiltersEnabled
        rebuildMenus(applyAlphaImmediately: !overlayChanged)
        if overlayChanged {
            animateStatusItemIcon(activating: newState.overlayFiltersEnabled, style: newState.iconStyle)
        }
    }

    // MARK: - Menu Construction

    /// Prepares the underlying status item button and initial menus.
    private func configureStatusItem() {
        guard let statusButton = statusItem.button else { return }
        statusButton.title = ""
        statusButton.target = self
        statusButton.action = #selector(handleClick(_:))
        statusButton.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusButton.imagePosition = .imageOnly
        statusButton.imageScaling = .scaleProportionallyDown
        statusButton.toolTip = localized("Focusly")
        updateMenuTitles()
        rebuildMenus()
    }

    /// Recreates the primary status bar menu, reflecting the latest state and localization.
    private func rebuildMenus(applyAlphaImmediately: Bool = true) {
        updateMenuTitles()
        statusItem.button?.toolTip = localized("Focusly")
        let statusIconTone = resolvedStatusBarIconTone()
        updateStatusItemIcon(tone: statusIconTone, applyAlpha: applyAlphaImmediately)

        mainMenu.removeAllItems()
        mainMenu.addItem(makeVersionMenuItem())
        mainMenu.addItem(.separator())

        let overlayToggleTitle = localized(state.overlayFiltersEnabled ? "Disable Overlays" : "Enable Overlays")
        let overlayToggleItem = NSMenuItem(title: overlayToggleTitle, action: #selector(toggleOverlay), keyEquivalent: "")
        overlayToggleItem.target = self
        overlayToggleItem.state = state.overlayFiltersEnabled ? .on : .off
        mainMenu.addItem(overlayToggleItem)

        mainMenu.addItem(.separator())

        let presetsTitle = localized("Presets")
        let presetsItem = NSMenuItem(title: presetsTitle, action: nil, keyEquivalent: "")
        let presetsSubmenu = NSMenu(title: presetsTitle)
        for preset in state.presetOptions {
            presetsSubmenu.addItem(makePresetMenuItem(for: preset))
        }
        presetsSubmenu.addItem(.separator())

        let preferencesTitle = localized("Preferences…")
        let preferencesMenuItem = NSMenuItem(title: preferencesTitle, action: #selector(openPreferences), keyEquivalent: "")
        preferencesMenuItem.target = self
        presetsSubmenu.addItem(preferencesMenuItem)
        presetsItem.submenu = presetsSubmenu
        mainMenu.addItem(presetsItem)

        mainMenu.addItem(.separator())

        let hotkeyToggleTitle = localized(state.hotkeysEnabled ? "Disable Shortcut" : "Enable Shortcut")
        let hotkeyToggleMenuItem = NSMenuItem(title: hotkeyToggleTitle, action: #selector(toggleHotkeys), keyEquivalent: "")
        hotkeyToggleMenuItem.target = self
        hotkeyToggleMenuItem.state = state.hotkeysEnabled ? .on : .off
        hotkeyToggleMenuItem.isEnabled = state.hasShortcut
        mainMenu.addItem(hotkeyToggleMenuItem)

        if state.isLaunchAtLoginAvailable {
            let launchAtLoginTitle = localized("Launch at Login")
            let launchAtLoginItem = NSMenuItem(title: launchAtLoginTitle, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            launchAtLoginItem.target = self
            launchAtLoginItem.state = state.isLaunchAtLoginEnabled ? .on : .off
            mainMenu.addItem(launchAtLoginItem)
        } else if let message = state.launchAtLoginStatusMessage {
            let launchAtLoginStatusItem = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            launchAtLoginStatusItem.isEnabled = false
            mainMenu.addItem(launchAtLoginStatusItem)
        }

        let iconMenuTitle = localized("Status Bar Icon")
        let iconMenuItem = NSMenuItem(title: iconMenuTitle, action: nil, keyEquivalent: "")
        let iconMenu = NSMenu(title: iconMenuTitle)
        for style in StatusBarIconStyle.allCases {
            let title = style.localizedName
            let item = NSMenuItem(title: title, action: #selector(selectIconStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = style == state.iconStyle ? .on : .off
            item.image = StatusBarIconFactory.icon(
                style: style,
                isActive: state.overlayFiltersEnabled,
                tone: statusIconTone,
                template: false
            )
            iconMenu.addItem(item)
        }
        iconMenuItem.submenu = iconMenu
        mainMenu.addItem(.separator())
        mainMenu.addItem(iconMenuItem)

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

    /// Builds the compact context menu shown on right-click or control-click.
    private func rebuildQuickMenu() {
        quickMenu.removeAllItems()
        // Use a compact version header for the quick/context menu so it doesn't force a wide menu.
        quickMenu.addItem(makeVersionMenuItem(compact: true))
        quickMenu.addItem(.separator())

        let toggleTitle = localized(state.overlayFiltersEnabled ? "Disable Overlays" : "Enable Overlays")
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleOverlay), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = state.overlayFiltersEnabled ? .on : .off
        quickMenu.addItem(toggleItem)

        quickMenu.addItem(.separator())

        let presetsTitle = localization.localized("Preset", fallback: "Preset")
        let presetsHeader = NSMenuItem(title: presetsTitle, action: nil, keyEquivalent: "")
        presetsHeader.isEnabled = false
        presetsHeader.attributedTitle = compactAttributedTitle(presetsTitle)
        quickMenu.addItem(presetsHeader)

        for preset in state.presetOptions {
            quickMenu.addItem(makePresetMenuItem(for: preset, compact: true))
        }

        quickMenu.addItem(.separator())

        if state.isLaunchAtLoginAvailable {
            let loginTitle = localized("Launch at Login")
            let loginItem = NSMenuItem(title: loginTitle, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            loginItem.target = self
            loginItem.state = state.isLaunchAtLoginEnabled ? .on : .off
            quickMenu.addItem(loginItem)
        } else if let message = state.launchAtLoginStatusMessage {
            // Use a short, 5-word variant for the quick/context menu to avoid excessive width.
            let shortMessage = abbreviatedFiveWords(message)
            let loginItem = NSMenuItem(title: shortMessage, action: nil, keyEquivalent: "")
            loginItem.isEnabled = false
            quickMenu.addItem(loginItem)
        }

        quickMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: localized("Settings…"), action: #selector(openPreferences), keyEquivalent: "")
        settingsItem.target = self
        quickMenu.addItem(settingsItem)

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

        // Apply compact styling (smaller font + truncation) to all quick menu items to limit width.
        for item in quickMenu.items {
            // Leave separators and items with custom views alone.
            if item.isSeparatorItem || item.view != nil { continue }
            // Preserve existing state/key equivalents while replacing the visible title with an attributed, truncated one.
            item.attributedTitle = compactAttributedTitle(item.title)
        }
    }

    /// Creates the standard version header shown in the main menu.
    private func makeVersionMenuItem() -> NSMenuItem {
        let title = "Focusly · \(FocuslyBuildInfo.marketingVersion)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // Compact variant used for the quick/context menu to avoid excessive width.
    /// Compact variant of the version header for the quick menu.
    private func makeVersionMenuItem(compact: Bool) -> NSMenuItem {
        if compact {
            let item = NSMenuItem(title: "Focusly", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = compactVersionAttributedTitle(
                name: "Focusly",
                version: FocuslyBuildInfo.marketingVersion
            )
            return item
        } else {
            return makeVersionMenuItem()
        }
    }

    /// Builds a menu item for a preset, optionally using the compact style.
    private func makePresetMenuItem(for preset: FocusPreset, compact: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = preset.id
        item.state = preset.id == state.activePresetIdentifier ? .on : .off
        if compact {
            item.attributedTitle = compactAttributedTitle(preset.name)
        }
        return item
    }

    // MARK: - Actions

    /// Forwards the enable/disable command to the delegate.
    @objc private func toggleOverlay() {
        delegate?.statusBarDidToggleEnabled(self)
    }

    /// Handles preset menu selection and notifies the delegate.
    @objc private func selectPreset(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        let preset = PresetLibrary.preset(withID: id)
        delegate?.statusBar(self, selectedPreset: preset)
    }

    /// Reports icon style changes back to the delegate.
    @objc private func selectIconStyle(_ item: NSMenuItem) {
        guard
            let raw = item.representedObject as? String,
            let style = StatusBarIconStyle(rawValue: raw)
        else {
            return
        }
        delegate?.statusBar(self, didSelectIconStyle: style)
    }

    /// Toggles the global hotkey preference via the delegate.
    @objc private func toggleHotkeys() {
        delegate?.statusBarDidToggleHotkeys(self)
    }

    /// Requests that the delegate flip the launch-at-login option.
    @objc private func toggleLaunchAtLogin() {
        delegate?.statusBarDidToggleLaunchAtLogin(self)
    }

    /// Opens the preferences window when the menu item is selected.
    @objc private func openPreferences() {
        delegate?.statusBarDidRequestPreferences(self)
    }

    /// Asks the delegate to replay the onboarding flow.
    @objc private func showOnboarding() {
        delegate?.statusBarDidRequestOnboarding(self)
    }

    /// Passes the quit request up to the app coordinator.
    @objc private func quitApp() {
        delegate?.statusBarDidRequestQuit(self)
    }

    // MARK: - Presentation

    /// Routes status item clicks to either toggle overlays or open menus.
    @objc private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            showMainMenu()
            return
        }

        switch event.type {
        case .rightMouseUp, .rightMouseDown:
            showQuickMenu(with: event)
        case .leftMouseUp:
            if shouldHandleMaskingToggle(for: event) {
                let targetDisplayID = displayIdentifier(for: event)
                delegate?.statusBar(self, didToggleMaskingModeFor: targetDisplayID)
            } else if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control) {
                showMainMenu()
            } else {
                toggleOverlay()
            }
        case .leftMouseDown:
            break
        default:
            showMainMenu()
        }
    }

    /// Shows the full status menu anchored to the status item.
    private func showMainMenu() {
        if let button = statusItem.button {
            statusItem.menu = mainMenu
            button.performClick(nil)
            statusItem.menu = nil
        }
    }

    /// Presents the compact quick menu for context-click interactions.
    private func showQuickMenu(with event: NSEvent) {
        if let button = statusItem.button {
            statusItem.menu = quickMenu
            NSMenu.popUpContextMenu(quickMenu, with: event, for: button)
            statusItem.menu = nil
        }
    }

    // MARK: - Localization

    /// Applies localized titles to the primary and quick menus.
    private func updateMenuTitles() {
        mainMenu.title = localized("Focusly")
        quickMenu.title = localized("Quick Actions")
    }

    /// Convenience accessor for localized strings scoped to status bar UI.
    private func localized(_ key: String) -> String {
        localization.localized(key, fallback: key)
    }

    // Return a compact attributed title (smaller menu font + truncation) used for quick/context menu items.
    /// Applies condensed typography so quick menu items stay narrow.
    private func compactAttributedTitle(_ title: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        // Slightly smaller than the default menu font to reduce width.
        let font = NSFont.menuFont(ofSize: 13)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        return NSAttributedString(string: title, attributes: attrs)
    }

    /// Styled "Focusly vX.Y" header for the compact context menu.
    private func compactVersionAttributedTitle(name: String, version: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.menuFont(ofSize: 13)

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let versionAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]

        let attributed = NSMutableAttributedString(string: "\(name) ", attributes: baseAttrs)
        attributed.append(NSAttributedString(string: version, attributes: versionAttrs))
        return attributed
    }

    // Produce a short version of a message by keeping at most the first five words and adding an ellipsis if truncated.
    /// Truncates a message to five words with an ellipsis to fit tight menu widths.
    private func abbreviatedFiveWords(_ message: String) -> String {
        let words = message.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        guard words.count > 5 else { return message }
        return words.prefix(5).joined(separator: " ") + "…"
    }

    /// Determines whether a shift-click should toggle the masking mode instead of the overlay flag.
    private func shouldHandleMaskingToggle(for event: NSEvent) -> Bool {
        guard event.type == .leftMouseUp else { return false }
        let modifiers = event.modifierFlags
        let shiftHeld = modifiers.contains(.shift)
        let conflictingModifier = modifiers.contains(.option) || modifiers.contains(.control) || modifiers.contains(.command)
        return shiftHeld && !conflictingModifier
    }

    /// Attempts to map the current pointer location to a display identifier for per-screen toggles.
    private func displayIdentifier(for event: NSEvent) -> DisplayID? {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else {
            return nil
        }
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return DisplayID(truncating: number)
    }
    
    /// Updates the status item artwork to match the active state and appearance tone.
    private func updateStatusItemIcon(tone providedTone: StatusBarIconTone? = nil, applyAlpha: Bool = true) {
        guard let button = statusItem.button else { return }
        let tone = providedTone ?? resolvedStatusBarIconTone()
        let isActive = state.overlayFiltersEnabled
        let icon = StatusBarIconFactory.icon(style: state.iconStyle, isActive: isActive, tone: tone)
        button.image = icon
        button.alternateImage = icon
        if applyAlpha {
            button.alphaValue = StatusBarController.statusItemAlpha(isActive: state.overlayFiltersEnabled)
        }
    }

    /// Runs a short Core Animation sequence on the status icon whenever overlay filters toggle.
    private func animateStatusItemIcon(activating isActivating: Bool, style: StatusBarIconStyle) {
        guard let button = statusItem.button else { return }
        if button.layer == nil {
            button.wantsLayer = true
        }
        guard let layer = button.layer else { return }

        let duration: CFTimeInterval = 0.38
        let targetAlpha = StatusBarController.statusItemAlpha(isActive: isActivating)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.animator().alphaValue = targetAlpha
        }

        let scaleValues: [NSNumber]
        if isActivating {
            scaleValues = [1.0, 1.16, 0.95, 1.0].map { NSNumber(value: $0) }
        } else {
            scaleValues = [1.0, 0.9, 1.04, 1.0].map { NSNumber(value: $0) }
        }

        let scaleAnimation = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnimation.values = scaleValues
        scaleAnimation.keyTimes = [0.0, 0.35, 0.7, 1.0].map { NSNumber(value: $0) }
        scaleAnimation.duration = duration
        scaleAnimation.timingFunctions = (0..<scaleValues.count - 1).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
        scaleAnimation.isRemovedOnCompletion = true
        scaleAnimation.fillMode = .forwards

        layer.removeAnimation(forKey: "focusly.status.scale")
        layer.add(scaleAnimation, forKey: "focusly.status.scale")

        switch style {
        case .dot:
            let opacityAnimation = CAKeyframeAnimation(keyPath: "opacity")
            let opacityValues: [NSNumber]
            if isActivating {
                opacityValues = [1.0, 1.0, 0.92, 1.0].map { NSNumber(value: $0) }
            } else {
                let restingAlpha = Double(StatusBarController.inactiveStatusAlpha)
                // Ease towards the resting opacity without returning to full intensity to avoid a visible flash.
                let easedValues = [
                    1.0,
                    min(1.0, restingAlpha + 0.14),
                    min(1.0, restingAlpha + 0.06),
                    restingAlpha
                ]
                opacityValues = easedValues.map { NSNumber(value: $0) }
            }
            opacityAnimation.values = opacityValues
            opacityAnimation.keyTimes = [0.0, 0.35, 0.7, 1.0].map { NSNumber(value: $0) }
            opacityAnimation.duration = duration * 0.9
            opacityAnimation.timingFunctions = (0..<opacityValues.count - 1).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
            opacityAnimation.isRemovedOnCompletion = true
            opacityAnimation.fillMode = .forwards

            layer.removeAnimation(forKey: "focusly.status.opacity")
            layer.add(opacityAnimation, forKey: "focusly.status.opacity")
        case .halo:
            let rotationAnimation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            let rotationValues = isActivating
                ? [0.0, 0.22, -0.12, 0.0]
                : [0.0, -0.2, 0.1, 0.0]
            rotationAnimation.values = rotationValues.map { NSNumber(value: $0) }
            rotationAnimation.keyTimes = [0.0, 0.3, 0.65, 1.0].map { NSNumber(value: $0) }
            rotationAnimation.duration = duration * 1.1
            rotationAnimation.timingFunctions = (0..<rotationValues.count - 1).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
            rotationAnimation.isRemovedOnCompletion = true
            rotationAnimation.fillMode = .forwards

            layer.removeAnimation(forKey: "focusly.status.rotation")
            layer.add(rotationAnimation, forKey: "focusly.status.rotation")
        case .pulse:
            let translationAnimation = CAKeyframeAnimation(keyPath: "transform.translation.y")
            let translationValues = isActivating
                ? [0.0, -1.6, 0.75, 0.0]
                : [0.0, 1.3, -0.45, 0.0]
            translationAnimation.values = translationValues.map { NSNumber(value: $0) }
            translationAnimation.keyTimes = [0.0, 0.3, 0.65, 1.0].map { NSNumber(value: $0) }
            translationAnimation.duration = duration
            translationAnimation.timingFunctions = (0..<translationValues.count - 1).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
            translationAnimation.isRemovedOnCompletion = true
            translationAnimation.fillMode = .forwards

            layer.removeAnimation(forKey: "focusly.status.translation")
            layer.add(translationAnimation, forKey: "focusly.status.translation")

            let lateralAnimation = CAKeyframeAnimation(keyPath: "transform.translation.x")
            let lateralValues = isActivating
                ? [0.0, 0.5, -0.3, 0.0]
                : [0.0, -0.45, 0.25, 0.0]
            lateralAnimation.values = lateralValues.map { NSNumber(value: $0) }
            lateralAnimation.keyTimes = translationAnimation.keyTimes
            lateralAnimation.duration = duration
            lateralAnimation.timingFunctions = translationAnimation.timingFunctions
            lateralAnimation.isRemovedOnCompletion = true
            lateralAnimation.fillMode = .forwards

            layer.removeAnimation(forKey: "focusly.status.translationX")
            layer.add(lateralAnimation, forKey: "focusly.status.translationX")
        }
    }

    /// Determines whether the status bar is currently light or dark for icon rendering.
    private func resolvedStatusBarIconTone() -> StatusBarIconTone {
        let appearanceSources: [NSAppearance?] = [
            statusItem.button?.window?.effectiveAppearance,
            statusItem.button?.effectiveAppearance,
            NSApp.effectiveAppearance
        ]

        for appearance in appearanceSources {
            guard let appearance else { continue }
            if let tone = StatusBarController.derivedTone(from: appearance) {
                return tone
            }
        }

        return .light
    }
}

private extension StatusBarController {
    static let inactiveStatusAlpha: CGFloat = 0.50

    static func statusItemAlpha(isActive: Bool) -> CGFloat {
        isActive ? 1.0 : inactiveStatusAlpha
    }

    /// Infers appearance tone by sampling the resolved label color brightness.
    static func derivedTone(from appearance: NSAppearance) -> StatusBarIconTone? {
        var resolvedColor = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = NSColor.labelColor
        }

        let converted = resolvedColor.usingColorSpace(NSColorSpace.extendedSRGB)
            ?? resolvedColor.usingColorSpace(NSColorSpace.deviceRGB)
            ?? resolvedColor.usingColorSpace(NSColorSpace.genericRGB)

        guard let color = converted else { return nil }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let brightness = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        return brightness >= 0.5 ? .light : .dark
    }
}

@objc private extension StatusBarController {
    /// Responds to appearance changes by redrawing icons and menus.
    func handleAppearanceChange() {
        rebuildMenus()
    }
}
/// Categorises the menu bar appearance so icons can swap palettes.
enum StatusBarIconTone: Hashable {
    case light
    case dark
}

/// Draws custom menu bar icons and caches them per appearance tone.
@MainActor
enum StatusBarIconFactory {
    private static let iconSize: CGFloat = 18
    private static let canvasSize = NSSize(width: iconSize, height: iconSize)
    private static var cache: [CacheKey: NSImage] = [:]

    /// Convenience overload that renders template icons for the status item.
    static func icon(style: StatusBarIconStyle, isActive: Bool) -> NSImage {
        icon(style: style, isActive: isActive, tone: .light, template: true)
    }

    /// Returns a cached or newly drawn icon for the supplied style.
    static func icon(
        style: StatusBarIconStyle,
        isActive: Bool,
        tone: StatusBarIconTone,
        template: Bool = true
    ) -> NSImage {
        let key = CacheKey(style: style, isActive: isActive, tone: tone, template: template)
        if let image = cache[key] {
            return image
        }

        let palette = palette(for: tone)
        let image: NSImage

        switch style {
        case .dot:
            image = drawDotIcon(isActive: isActive, palette: palette, template: template)
        case .halo:
            image = drawHaloIcon(isActive: isActive, palette: palette, template: template)
        case .pulse:
            image = drawPulseIcon(isActive: isActive, palette: palette, template: template)
        }

        cache[key] = image
        return image
    }

    /// Selects the color palette appropriate for the current menu bar tone.
    private static func palette(for tone: StatusBarIconTone) -> IconPalette {
        switch tone {
        case .light:
            return IconPalette(
                primary: .white,
                highlight: NSColor.white.withAlphaComponent(0.45),
                glow: NSColor.white.withAlphaComponent(0.35)
            )
        case .dark:
            return IconPalette(
                primary: .black,
                highlight: NSColor.white.withAlphaComponent(0.25),
                glow: NSColor.black.withAlphaComponent(0.2)
            )
        }
    }

    /// Renders the dot icon variant with filled or outlined states.
    private static func drawDotIcon(isActive: Bool, palette: IconPalette, template: Bool) -> NSImage {
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let diameter = rect.width * (isActive ? 0.42 : 0.46)
            let circleRect = NSRect(
                x: rect.midX - diameter / 2,
                y: rect.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            let circle = NSBezierPath(ovalIn: circleRect)
            if isActive {
                palette.primary.setFill()
                circle.fill()
            } else {
                circle.lineWidth = rect.width * 0.14
                palette.primary.setStroke()
                circle.stroke()
            }
            return true
        }
        image.isTemplate = template
        return image
    }

    /// Renders the equalizer-style icon with animated bars when active.
    private static func drawPulseIcon(isActive: Bool, palette: IconPalette, template: Bool) -> NSImage {
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let barWidth = rect.width * 0.18
            let cornerRadius = barWidth / 2

            /// Draws a single equalizer bar at the provided offset and height.
            func drawBar(offset: CGFloat, height: CGFloat) {
                let barRect = NSRect(
                    x: rect.midX + offset - barWidth / 2,
                    y: rect.midY - height / 2,
                    width: barWidth,
                    height: height
                )
                let bar = NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius)
                palette.primary.setFill()
                bar.fill()
            }

            if isActive {
                let spacing = barWidth * 0.9
                drawBar(offset: -spacing - barWidth, height: rect.height * 0.58)
                drawBar(offset: 0, height: rect.height * 0.82)
                drawBar(offset: spacing + barWidth, height: rect.height * 0.46)
            } else {
                drawBar(offset: 0, height: rect.height * 0.6)
            }
            return true
        }
        image.isTemplate = template
        return image
    }

    /// Renders the halo icon variation using either a filled circle or outlined ring.
    private static func drawHaloIcon(isActive: Bool, palette: IconPalette, template: Bool) -> NSImage {
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let minDimension = min(rect.width, rect.height)

            if isActive {
                let circleInset = minDimension * 0.14
                let circleRect = rect.insetBy(dx: circleInset, dy: circleInset)
                let circle = NSBezierPath(ovalIn: circleRect)
                palette.primary.setFill()
                circle.fill()

                let highlightInset = circleRect.width * 0.4
                var highlightRect = circleRect
                highlightRect.origin.x -= circleRect.width * 0.1
                highlightRect.origin.y += circleRect.height * 0.15
                highlightRect = highlightRect.insetBy(dx: highlightInset, dy: highlightInset)
                if highlightRect.width > 0 && highlightRect.height > 0 {
                    let highlight = NSBezierPath(ovalIn: highlightRect)
                    palette.highlight.setFill()
                    highlight.fill()
                }
            } else {
                let outerInset = minDimension * 0.17
                let outerRect = rect.insetBy(dx: outerInset, dy: outerInset)
                let ring = NSBezierPath(ovalIn: outerRect)
                ring.lineWidth = minDimension * 0.1
                palette.primary.setStroke()
                ring.stroke()

                let glowInset = minDimension * 0.19
                let softGlowRect = outerRect.insetBy(dx: glowInset, dy: glowInset)
                if softGlowRect.width > 0 && softGlowRect.height > 0 {
                    let glow = NSBezierPath(ovalIn: softGlowRect)
                    palette.glow.setFill()
                    glow.fill()
                }
            }

            return true
        }
        image.isTemplate = template
        return image
    }

    /// Cache key capturing the factors that affect icon rendering.
    private struct CacheKey: Hashable {
        let style: StatusBarIconStyle
        let isActive: Bool
        let tone: StatusBarIconTone
        let template: Bool
    }

    /// Simple color bundle used while rasterizing icons.
    private struct IconPalette {
        let primary: NSColor
        let highlight: NSColor
        let glow: NSColor
    }
}
