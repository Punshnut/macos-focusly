import Foundation
import ServiceManagement

@MainActor
protocol LaunchAtLoginManaging {
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }

    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
}

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
final class LaunchAtLoginManager: LaunchAtLoginManaging {
    private enum Availability {
        case available
        case requiresAppBundle
    }

    private let availability: Availability
    private let service: SMAppService?
    private let localization: LocalizationService

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

    var isAvailable: Bool {
        availability == .available
    }

    var unavailableReason: String? {
        guard !isAvailable else { return nil }
        return unavailableMessage()
    }

    func isEnabled() -> Bool {
        guard let service, isAvailable else { return false }
        return service.status == .enabled
    }

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

    private static func isRunningFromAppBundle(_ bundle: Bundle) -> Bool {
        guard let packageType = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String else {
            return false
        }
        return packageType == "APPL"
    }

    private func unavailableMessage() -> String {
        localization.localized(
            "Launch at Login requires Focusly to run from a signed app bundle. Build and run the app bundle instead of the command-line target to enable this option.",
            fallback: "Launch at Login requires Focusly to run from a signed app bundle. Build and run the app bundle instead of the command-line target to enable this option."
        )
    }
}
