import AppKit

struct FocuslyEnvironment {
    let userDefaults: UserDefaults
    let notificationCenter: NotificationCenter
    let workspace: NSWorkspace
    let launchAtLogin: LaunchAtLoginManaging

    static let `default` = FocuslyEnvironment(
        userDefaults: .standard,
        notificationCenter: .default,
        workspace: .shared,
        launchAtLogin: LaunchAtLoginManager()
    )
}
