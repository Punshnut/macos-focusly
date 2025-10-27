import AppKit

@main
@MainActor
final class FocuslyMain: NSObject, NSApplicationDelegate {
    private var coordinator: FocuslyAppCoordinator?

    static func main() {
        let application = NSApplication.shared
        let delegate = FocuslyMain()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        let environment = FocuslyEnvironment.default
        coordinator = FocuslyAppCoordinator(environment: environment)
        coordinator?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

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
