import Foundation
import ServiceManagement

protocol LaunchAtLoginManaging {
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }

    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
}

enum LaunchAtLoginError: LocalizedError {
    case unavailable(reason: String?)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason ?? NSLocalizedString(
                "Launch at Login is unavailable in the current build.",
                tableName: nil,
                bundle: .module,
                value: "Launch at Login is unavailable in the current build.",
                comment: "Fallback message when login items cannot be managed."
            )
        }
    }
}

final class LaunchAtLoginManager: LaunchAtLoginManaging {
    private enum Availability {
        case available
        case requiresAppBundle
    }

    private let availability: Availability
    private let service: SMAppService?

    init(bundle: Bundle = .main) {
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
        return NSLocalizedString(
            "Launch at Login requires Focusly to run from a signed app bundle. Build and run the app bundle instead of the command-line target to enable this option.",
            tableName: nil,
            bundle: .module,
            value: "Launch at Login requires Focusly to run from a signed app bundle. Build and run the app bundle instead of the command-line target to enable this option.",
            comment: "Explains why launch at login is unavailable when the app is running unsigned in Xcode."
        )
    }

    func isEnabled() -> Bool {
        guard let service, isAvailable else { return false }
        return service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        guard let service, isAvailable else {
            throw LaunchAtLoginError.unavailable(reason: unavailableReason)
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
}
