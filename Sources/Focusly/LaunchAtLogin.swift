import Foundation
import ServiceManagement

/// Abstraction over macOS launch-at-login enrollment so UI can react to availability.
@MainActor
protocol LaunchAtLoginManaging {
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }

    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
}

/// Error domain surfaced when launch-at-login cannot be configured.
enum LaunchAtLoginError: LocalizedError {
    case unavailable(reason: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        }
    }
}

@MainActor
/// Concrete implementation that bridges `SMAppService` while handling sandbox limitations.
final class LaunchAtLoginManager: LaunchAtLoginManaging {
    private enum Availability {
        case available
        case requiresAppBundle
    }

    private let availability: Availability
    private let service: SMAppService?
    private let localization: LocalizationService

    /// Initializes the manager, detecting whether the current target supports login item registration.
    init(bundle: Bundle = .main, localization: LocalizationService? = nil) {
        self.localization = localization ?? LocalizationService.shared
        if LaunchAtLoginManager.isRunningFromAppBundle(bundle) {
            availability = .available
            service = SMAppService.mainApp
        } else {
            availability = .requiresAppBundle
            service = nil
        }
    }

    /// Indicates whether the host bundle supports launch-at-login registration.
    var isAvailable: Bool {
        availability == .available
    }

    /// Localized explanation shown when the feature cannot be enabled.
    var unavailableReason: String? {
        guard !isAvailable else { return nil }
        return unavailableMessage()
    }

    /// Checks the current registration state, returning false for unsupported targets.
    func isEnabled() -> Bool {
        guard let service, isAvailable else { return false }
        return service.status == .enabled
    }

    /// Attempts to register or unregister the app as a login item, throwing if unsupported.
    func setEnabled(_ enabled: Bool) throws {
        guard let service, isAvailable else {
            throw LaunchAtLoginError.unavailable(reason: unavailableMessage())
        }

        switch (enabled, service.status) {
        case (true, .enabled), (false, .notRegistered):
            return
        case (true, _):
            try service.register()
        case (false, _):
            try service.unregister()
        }
    }

    /// Detects whether the executable is running from an `.app` bundle rather than a CLI target.
    private static func isRunningFromAppBundle(_ bundle: Bundle) -> Bool {
        guard let packageType = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String else {
            return false
        }
        return packageType == "APPL"
    }

    /// Returns a localized explanation for why launch-at-login cannot be toggled.
    private func unavailableMessage() -> String {
        localization.localized(
            "Launch at Login requires Focusly to run from a signed app bundle. Build and run the app bundle instead of the command-line target to enable this option.",
            fallback: "Launch at Login requires Focusly to run from a signed app bundle. Build and run the app bundle instead of the command-line target to enable this option."
        )
    }
}
