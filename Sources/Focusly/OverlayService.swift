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
            overlayWindows.values.forEach { overlay in
                overlay.setFiltersEnabled(appSettings.areFiltersEnabled)
                overlay.prepareForPresentation()
                overlay.orderFrontRegardless()
                let style = profileStore.style(forDisplayID: overlay.associatedDisplayIdentifier())
                overlay.apply(style: style, animated: animated)
            }
        } else {
            overlayWindows.values.forEach { $0.hide(animated: animated) }
        }
        delegate?.overlayService(self, didUpdateOverlays: overlayWindows)
    }

    /// Reconciles overlay windows with the currently connected displays and updates their frames and styles.
    func refreshDisplays(animated: Bool, shouldApplyStyles: Bool = true) {
        let screens = NSScreen.screens
        var connectedDisplayIDs = Set<DisplayID>()

        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = DisplayID(truncating: number)
            connectedDisplayIDs.insert(displayID)

            if let overlay = overlayWindows[displayID] {
                overlay.updateFrame(to: screen)
            } else {
                let overlay = OverlayWindow(screen: screen, displayIdentifier: displayID)
                overlay.setFiltersEnabled(appSettings.areFiltersEnabled)
                overlayWindows[displayID] = overlay
                if isActive {
                    overlay.orderFrontRegardless()
                }
            }

            if let overlay = overlayWindows[displayID], isActive, shouldApplyStyles {
                let style = profileStore.style(forDisplayID: displayID)
                overlay.apply(style: style, animated: animated)
            }
        }

        profileStore.removeInvalidOverrides(validDisplayIDs: connectedDisplayIDs)

        let disconnectedDisplayIDs = overlayWindows.keys.filter { !connectedDisplayIDs.contains($0) }
        for displayID in disconnectedDisplayIDs {
            overlayWindows[displayID]?.orderOut(nil)
            overlayWindows.removeValue(forKey: displayID)
        }

        delegate?.overlayService(self, didUpdateOverlays: overlayWindows)
    }

    /// Reapplies the stored style for the specified display.
    func updateStyle(for displayID: DisplayID, animated: Bool) {
        guard let overlay = overlayWindows[displayID], isActive else { return }
        overlay.apply(style: profileStore.style(forDisplayID: displayID), animated: animated)
    }

    /// Enables or disables blur/tint filters across all overlay windows.
    private func updateFilterActivationState(_ isEnabled: Bool) {
        overlayWindows.values.forEach { $0.setFiltersEnabled(isEnabled) }
    }
}
