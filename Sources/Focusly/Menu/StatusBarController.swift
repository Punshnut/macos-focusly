import AppKit

enum StatusBarIconStyle: String, CaseIterable, Codable, Equatable, Hashable {
    case dot
    case halo
    case pulse

    var localizedName: String {
        switch self {
        case .dot:
            return NSLocalizedString(
                "Minimal Dot",
                tableName: nil,
                bundle: .module,
                value: "Minimal Dot",
                comment: "Status bar icon option representing a small dot."
            )
        case .halo:
            return NSLocalizedString(
                "Halo",
                tableName: nil,
                bundle: .module,
                value: "Halo",
                comment: "Status bar icon option representing a halo outline."
            )
        case .pulse:
            return NSLocalizedString(
                "Equalizer",
                tableName: nil,
                bundle: .module,
                value: "Equalizer",
                comment: "Status bar icon option representing stacked bars."
            )
        }
    }
}

struct StatusBarState {
    var enabled: Bool
    var hotkeysEnabled: Bool
    var hasShortcut: Bool
    var launchAtLoginEnabled: Bool
    var launchAtLoginAvailable: Bool
    var launchAtLoginMessage: String?
    var activePresetID: String
    var presets: [FocusPreset]
    var iconStyle: StatusBarIconStyle
}

@MainActor
protocol StatusBarControllerDelegate: AnyObject {
    func statusBarDidToggleEnabled(_ controller: StatusBarController)
    func statusBar(_ controller: StatusBarController, selectedPreset preset: FocusPreset)
    func statusBar(_ controller: StatusBarController, didSelectIconStyle style: StatusBarIconStyle)
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
        presets: PresetLibrary.presets,
        iconStyle: .dot
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
        button.title = ""
        button.target = self
        button.action = #selector(handleClick(_:))
        button.appearance = NSAppearance(named: .vibrantLight)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = localized("Focusly")

        mainMenu.autoenablesItems = false
        mainMenu.appearance = NSAppearance(named: .vibrantLight)
        quickMenu.autoenablesItems = false
        quickMenu.appearance = NSAppearance(named: .vibrantLight)

        updateStatusItemIcon()
        rebuildMenus()
    }

    private func rebuildMenus() {
        updateStatusItemIcon()

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
            presetsMenu.addItem(makePresetMenuItem(for: preset))
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

        let iconMenuTitle = localized("Status Bar Icon")
        let iconMenuItem = NSMenuItem(title: iconMenuTitle, action: nil, keyEquivalent: "")
        let iconMenu = NSMenu(title: iconMenuTitle)
        for style in StatusBarIconStyle.allCases {
            let title = style.localizedName
            let item = NSMenuItem(title: title, action: #selector(selectIconStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = style == state.iconStyle ? .on : .off
            item.image = StatusBarIconFactory.icon(style: style, isActive: state.enabled)
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

    private func rebuildQuickMenu() {
            quickMenu.removeAllItems()
            // Use a compact version header for the quick/context menu so it doesn't force a wide menu.
            quickMenu.addItem(makeVersionMenuItem(compact: true))
            quickMenu.addItem(.separator())

            let toggleTitle = localized(state.enabled ? "Disable Overlays" : "Enable Overlays")
            let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleOverlay), keyEquivalent: "")
            toggleItem.target = self
            toggleItem.state = state.enabled ? .on : .off
            quickMenu.addItem(toggleItem)

        quickMenu.addItem(.separator())

        let presetsTitle = localized("Presets")
        let presetsHeader = NSMenuItem(title: presetsTitle, action: nil, keyEquivalent: "")
        presetsHeader.isEnabled = false
        presetsHeader.attributedTitle = compactAttributedTitle(presetsTitle)
        quickMenu.addItem(presetsHeader)

        for preset in state.presets {
            quickMenu.addItem(makePresetMenuItem(for: preset, compact: true))
        }

        quickMenu.addItem(.separator())

        let hotkeyTitle = localized(state.hotkeysEnabled ? "Disable Shortcut" : "Enable Shortcut")
        let hotkeyItem = NSMenuItem(title: hotkeyTitle, action: #selector(toggleHotkeys), keyEquivalent: "")
        hotkeyItem.target = self
        hotkeyItem.state = state.hotkeysEnabled ? .on : .off
        hotkeyItem.isEnabled = state.hasShortcut
        quickMenu.addItem(hotkeyItem)

        if state.launchAtLoginAvailable {
            let loginKey = state.launchAtLoginEnabled ? "Launch at Login ✅" : "Launch at Login ⬜️"
            let loginTitle = localized(loginKey)
            let loginItem = NSMenuItem(title: loginTitle, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            loginItem.target = self
            loginItem.state = state.launchAtLoginEnabled ? .on : .off
            quickMenu.addItem(loginItem)
        } else if let message = state.launchAtLoginMessage {
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

    private func makeVersionMenuItem() -> NSMenuItem {
        let title = "Focusly · \(FocuslyBuildInfo.marketingVersion)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // Compact variant used for the quick/context menu to avoid excessive width.
    private func makeVersionMenuItem(compact: Bool) -> NSMenuItem {
        if compact {
            let item = NSMenuItem(title: "Focusly", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = compactAttributedTitle(item.title)
            return item
        } else {
            return makeVersionMenuItem()
        }
    }

    private func makePresetMenuItem(for preset: FocusPreset, compact: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = preset.id
        item.state = preset.id == state.activePresetID ? .on : .off
        if compact {
            item.attributedTitle = compactAttributedTitle(preset.name)
        }
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

    @objc private func selectIconStyle(_ item: NSMenuItem) {
        guard
            let raw = item.representedObject as? String,
            let style = StatusBarIconStyle(rawValue: raw)
        else {
            return
        }
        delegate?.statusBar(self, didSelectIconStyle: style)
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
        case .leftMouseUp:
            if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.control) {
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

    // Return a compact attributed title (smaller menu font + truncation) used for quick/context menu items.
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

    // Produce a short version of a message by keeping at most the first five words and adding an ellipsis if truncated.
    private func abbreviatedFiveWords(_ message: String) -> String {
        let words = message.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        guard words.count > 5 else { return message }
        return words.prefix(5).joined(separator: " ") + "…"
    }
    
    private func updateStatusItemIcon() {
        guard let button = statusItem.button else { return }
        button.image = StatusBarIconFactory.icon(style: state.iconStyle, isActive: state.enabled)
        button.alternateImage = StatusBarIconFactory.icon(style: state.iconStyle, isActive: true)
        button.contentTintColor = StatusBarIconFactory.tintColor(isActive: state.enabled)
        button.image?.isTemplate = true
    }
}

enum StatusBarIconFactory {
    private static let iconSize: CGFloat = 18
    private static let canvasSize = NSSize(width: iconSize, height: iconSize)

    static func icon(style: StatusBarIconStyle, isActive: Bool) -> NSImage {
        switch style {
        case .dot:
            return isActive ? dotActive : dotInactive
        case .halo:
            return isActive ? haloActive : haloInactive
        case .pulse:
            return isActive ? pulseActive : pulseInactive
        }
    }

    static func tintColor(isActive: Bool) -> NSColor {
        if isActive {
            return NSColor.white
        } else {
            return NSColor.secondaryLabelColor
        }
    }

    private static let dotActive: NSImage = {
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let diameter = rect.width * 0.42
            let circleRect = NSRect(
                x: rect.midX - diameter / 2,
                y: rect.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            let circle = NSBezierPath(ovalIn: circleRect)
            NSColor.white.setFill()
            circle.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static let dotInactive: NSImage = {
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let diameter = rect.width * 0.46
            let circleRect = NSRect(
                x: rect.midX - diameter / 2,
                y: rect.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            let circle = NSBezierPath(ovalIn: circleRect)
            circle.lineWidth = rect.width * 0.14
            NSColor.white.setStroke()
            circle.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static let haloActive: NSImage = {
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let circleRect = rect.insetBy(dx: 2.5, dy: 2.5)
            let circle = NSBezierPath(ovalIn: circleRect)
            NSColor.white.setFill()
            circle.fill()

            let highlightInset = circleRect.width * 0.4
            var highlightRect = circleRect
            highlightRect.origin.x -= circleRect.width * 0.1
            highlightRect.origin.y += circleRect.height * 0.15
            highlightRect = highlightRect.insetBy(dx: highlightInset, dy: highlightInset)
            if highlightRect.width > 0 && highlightRect.height > 0 {
                let highlight = NSBezierPath(ovalIn: highlightRect)
                NSColor.white.withAlphaComponent(0.45).setFill()
                highlight.fill()
            }

            return true
        }
        image.isTemplate = true
        return image
    }()

    private static let haloInactive: NSImage = {
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let outerRect = rect.insetBy(dx: 3, dy: 3)
            let ring = NSBezierPath(ovalIn: outerRect)
            ring.lineWidth = 1.8
            NSColor.white.setStroke()
            ring.stroke()

            let softGlowRect = outerRect.insetBy(dx: 3.5, dy: 3.5)
            if softGlowRect.width > 0 && softGlowRect.height > 0 {
                let glow = NSBezierPath(ovalIn: softGlowRect)
                NSColor.white.withAlphaComponent(0.35).setFill()
                glow.fill()
            }

            return true
        }
        image.isTemplate = true
        return image
    }()

    private static let pulseActive: NSImage = {
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let barWidth = rect.width * 0.18
            let spacing = barWidth * 0.9
            let cornerRadius = barWidth / 2

            func drawBar(offset: CGFloat, height: CGFloat) {
                let barRect = NSRect(
                    x: rect.midX + offset - barWidth / 2,
                    y: rect.midY - height / 2,
                    width: barWidth,
                    height: height
                )
                let bar = NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius)
                NSColor.white.setFill()
                bar.fill()
            }

            drawBar(offset: -spacing - barWidth, height: rect.height * 0.58)
            drawBar(offset: 0, height: rect.height * 0.82)
            drawBar(offset: spacing + barWidth, height: rect.height * 0.46)
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static let pulseInactive: NSImage = {
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let barWidth = rect.width * 0.18
            let cornerRadius = barWidth / 2
            let barRect = NSRect(
                x: rect.midX - barWidth / 2,
                y: rect.midY - (rect.height * 0.6) / 2,
                width: barWidth,
                height: rect.height * 0.6
            )
            let bar = NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.white.setFill()
            bar.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
