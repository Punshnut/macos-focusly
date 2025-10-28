import AppKit

private let applicationAppearanceNotificationName = Notification.Name("NSApplicationDidChangeEffectiveAppearanceNotification")

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
        configureStatusItem()
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: applicationAppearanceNotificationName, object: nil)
        DistributedNotificationCenter.default().removeObserver(self, name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
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
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = localized("Focusly")

        mainMenu.autoenablesItems = false
        mainMenu.appearance = NSAppearance(named: .vibrantLight)
        quickMenu.autoenablesItems = false
        quickMenu.appearance = NSAppearance(named: .vibrantLight)

        rebuildMenus()
    }

    private func rebuildMenus() {
        let tone = resolvedStatusBarIconTone()
        updateStatusItemIcon(tone: tone)

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
            item.image = StatusBarIconFactory.icon(
                style: style,
                isActive: state.enabled,
                tone: tone,
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
    
    private func updateStatusItemIcon(tone providedTone: StatusBarIconTone? = nil) {
        guard let button = statusItem.button else { return }
        let tone = providedTone ?? resolvedStatusBarIconTone()
        button.image = StatusBarIconFactory.icon(style: state.iconStyle, isActive: state.enabled, tone: tone)
        button.alternateImage = StatusBarIconFactory.icon(style: state.iconStyle, isActive: true, tone: tone)
    }

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
    func handleAppearanceChange() {
        rebuildMenus()
    }
}
enum StatusBarIconTone: Hashable {
    case light
    case dark
}

enum StatusBarIconFactory {
    private static let iconSize: CGFloat = 18
    private static let canvasSize = NSSize(width: iconSize, height: iconSize)
    private static var cache: [CacheKey: NSImage] = [:]

    static func icon(style: StatusBarIconStyle, isActive: Bool) -> NSImage {
        icon(style: style, isActive: isActive, tone: .light, template: true)
    }

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

    private static func drawPulseIcon(isActive: Bool, palette: IconPalette, template: Bool) -> NSImage {
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            let barWidth = rect.width * 0.18
            let cornerRadius = barWidth / 2

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

    private struct CacheKey: Hashable {
        let style: StatusBarIconStyle
        let isActive: Bool
        let tone: StatusBarIconTone
        let template: Bool
    }

    private struct IconPalette {
        let primary: NSColor
        let highlight: NSColor
        let glow: NSColor
    }
}
