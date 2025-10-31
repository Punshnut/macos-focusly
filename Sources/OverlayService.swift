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
    private let overlayProfileStore: ProfileStore
    private let globalSettings: AppSettings
    private var filterActivationCancellable: AnyCancellable?
    private var overlayWindowsByDisplay: [DisplayID: OverlayWindow] = [:]
    private var overlaysActive = false
    weak var delegate: OverlayServiceDelegate?

    /// Hooks into the profile store and settings to keep overlays up to date.
    init(overlayProfileStore: ProfileStore, globalSettings: AppSettings) {
        self.overlayProfileStore = overlayProfileStore
        self.globalSettings = globalSettings
        filterActivationCancellable = globalSettings.$overlayFiltersActive
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                self?.updateFilterActivationState(isEnabled)
            }
    }

    /// Turns overlay windows on or off and primes them with the latest style when becoming active.
    func setActive(_ isEnabled: Bool, animated: Bool) {
        guard overlaysActive != isEnabled else { return }
        overlaysActive = isEnabled
        if isEnabled {
            refreshDisplays(animated: false, shouldApplyStyles: false)
            overlayWindowsByDisplay.values.forEach { overlayWindow in
                overlayWindow.setFiltersEnabled(globalSettings.overlayFiltersActive)
                overlayWindow.prepareForPresentation()
                overlayWindow.orderFrontRegardless()
                let overlayStyle = overlayProfileStore.style(forDisplayID: overlayWindow.associatedDisplayIdentifier())
                overlayWindow.apply(style: overlayStyle, animated: animated)
            }
        } else {
            overlayWindowsByDisplay.values.forEach { $0.hide(animated: animated) }
        }
        delegate?.overlayService(self, didUpdateOverlays: overlayWindowsByDisplay)
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

            if let overlayWindow = overlayWindowsByDisplay[displayIdentifier] {
                overlayWindow.updateFrame(to: screen)
            } else {
                let overlayWindow = OverlayWindow(screen: screen, displayIdentifier: displayIdentifier)
                overlayWindow.setFiltersEnabled(globalSettings.overlayFiltersActive)
                overlayWindowsByDisplay[displayIdentifier] = overlayWindow
                if overlaysActive {
                    overlayWindow.orderFrontRegardless()
                }
            }

            if let overlayWindow = overlayWindowsByDisplay[displayIdentifier], overlaysActive, shouldApplyStyles {
                let overlayStyle = overlayProfileStore.style(forDisplayID: displayIdentifier)
                overlayWindow.apply(style: overlayStyle, animated: animated)
            }
        }

        overlayProfileStore.removeInvalidOverrides(validDisplayIDs: connectedDisplayIdentifiers)

        let disconnectedDisplayIdentifiers = overlayWindowsByDisplay.keys.filter { !connectedDisplayIdentifiers.contains($0) }
        for displayIdentifier in disconnectedDisplayIdentifiers {
            overlayWindowsByDisplay[displayIdentifier]?.orderOut(nil)
            overlayWindowsByDisplay.removeValue(forKey: displayIdentifier)
        }

        delegate?.overlayService(self, didUpdateOverlays: overlayWindowsByDisplay)
    }

    /// Reapplies the stored style for the specified display.
    func updateStyle(for displayID: DisplayID, animated: Bool) {
        guard let overlayWindow = overlayWindowsByDisplay[displayID], overlaysActive else { return }
        overlayWindow.apply(style: overlayProfileStore.style(forDisplayID: displayID), animated: animated)
    }

    /// Enables or disables blur/tint filters across all overlay windows.
    private func updateFilterActivationState(_ isEnabled: Bool) {
        overlayWindowsByDisplay.values.forEach { $0.setFiltersEnabled(isEnabled) }
    }
}
