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
        appMenu.addItem(withTitle: aboutTitle, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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
}
