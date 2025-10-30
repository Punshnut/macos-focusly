import AppKit

/// Injection container that bundles service clients used across the app.
struct FocuslyEnvironment {
    let userDefaults: UserDefaults
    let notificationCenter: NotificationCenter
    let workspace: NSWorkspace
    let launchAtLogin: LaunchAtLoginManaging

    @MainActor
    static let `default` = FocuslyEnvironment(
        userDefaults: .standard,
        notificationCenter: .default,
        workspace: .shared,
        launchAtLogin: LaunchAtLoginManager()
    )
}
