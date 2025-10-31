import AppKit
import Combine

/// Receives updates any time the overlay service changes its managed windows.
@MainActor
protocol OverlayServiceDelegate: AnyObject {
    func overlayService(_ service: OverlayService, didUpdateOverlays overlays: [DisplayID: OverlayWindow])
}

/// Creates and manages `OverlayWindow` instances for each connected display.
@MainActor
final class OverlayService {
    private let profileStore: ProfileStore
    private let appSettings: AppSettings
    private var filterActivationSubscription: AnyCancellable?
    private var overlayWindows: [DisplayID: OverlayWindow] = [:]
    private var isActive = false
    weak var delegate: OverlayServiceDelegate?

    /// Hooks into the profile store and settings to keep overlays up to date.
    init(profileStore: ProfileStore, appSettings: AppSettings) {
        self.profileStore = profileStore
        self.appSettings = appSettings
        filterActivationSubscription = appSettings.$areFiltersEnabled
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                self?.updateFilterActivationState(isEnabled)
            }
    }

    /// Turns overlay windows on or off and primes them with the latest style when becoming active.
    func setActive(_ isEnabled: Bool, animated: Bool) {
        guard isActive != isEnabled else { return }
        isActive = isEnabled
        if isEnabled {
            refreshDisplays(animated: false, shouldApplyStyles: false)
            overlayWindows.values.forEach { overlayWindow in
                overlayWindow.setFiltersEnabled(appSettings.areFiltersEnabled)
                overlayWindow.prepareForPresentation()
                overlayWindow.orderFrontRegardless()
                let overlayStyle = profileStore.style(forDisplayID: overlayWindow.associatedDisplayIdentifier())
                overlayWindow.apply(style: overlayStyle, animated: animated)
            }
        } else {
            overlayWindows.values.forEach { $0.hide(animated: animated) }
        }
        delegate?.overlayService(self, didUpdateOverlays: overlayWindows)
    }

    /// Reconciles overlay windows with the currently connected displays and updates their frames and styles.
    func refreshDisplays(animated: Bool, shouldApplyStyles: Bool = true) {
        let availableScreens = NSScreen.screens
        var connectedDisplayIdentifiers = Set<DisplayID>()

        for screen in availableScreens {
            guard let screenNumberValue = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayIdentifier = DisplayID(truncating: screenNumberValue)
            connectedDisplayIdentifiers.insert(displayIdentifier)

            if let overlayWindow = overlayWindows[displayIdentifier] {
                overlayWindow.updateFrame(to: screen)
            } else {
                let overlayWindow = OverlayWindow(screen: screen, displayIdentifier: displayIdentifier)
                overlayWindow.setFiltersEnabled(appSettings.areFiltersEnabled)
                overlayWindows[displayIdentifier] = overlayWindow
                if isActive {
                    overlayWindow.orderFrontRegardless()
                }
            }

            if let overlayWindow = overlayWindows[displayIdentifier], isActive, shouldApplyStyles {
                let overlayStyle = profileStore.style(forDisplayID: displayIdentifier)
                overlayWindow.apply(style: overlayStyle, animated: animated)
            }
        }

        profileStore.removeInvalidOverrides(validDisplayIDs: connectedDisplayIdentifiers)

        let disconnectedDisplayIdentifiers = overlayWindows.keys.filter { !connectedDisplayIdentifiers.contains($0) }
        for displayIdentifier in disconnectedDisplayIdentifiers {
            overlayWindows[displayIdentifier]?.orderOut(nil)
            overlayWindows.removeValue(forKey: displayIdentifier)
        }

        delegate?.overlayService(self, didUpdateOverlays: overlayWindows)
    }

    /// Reapplies the stored style for the specified display.
    func updateStyle(for displayID: DisplayID, animated: Bool) {
        guard let overlayWindow = overlayWindows[displayID], isActive else { return }
        overlayWindow.apply(style: profileStore.style(forDisplayID: displayID), animated: animated)
    }

    /// Enables or disables blur/tint filters across all overlay windows.
    private func updateFilterActivationState(_ isEnabled: Bool) {
        overlayWindows.values.forEach { $0.setFiltersEnabled(isEnabled) }
    }
}
