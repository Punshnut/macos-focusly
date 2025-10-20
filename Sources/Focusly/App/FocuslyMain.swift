import AppKit

@main
@MainActor
final class FocuslyMain: NSObject, NSApplicationDelegate {
    private var coordinator: FocuslyAppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
}
