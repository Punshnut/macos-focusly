import AppKit
import Combine

/// Receives updates any time the overlay service changes its managed windows.
@MainActor
protocol OverlayServiceDelegate: AnyObject {
    /// Overlay windows changed and the consumer should refresh its state.
    func overlayService(_ service: OverlayService, didUpdateOverlays overlays: [DisplayID: OverlayWindow])
}

/// Creates and manages `OverlayWindow` instances for each connected display.
@MainActor
final class OverlayService {
    private let profileStore: ProfileStore
    private let appSettings: AppSettings
    private var overlayFiltersSubscription: AnyCancellable?
    private var overlayWindowsByDisplayID: [DisplayID: OverlayWindow] = [:]
    private var menuBarWindowsByDisplayID: [DisplayID: MenuBarBackdropWindow] = [:]
    private var areOverlaysActive = false
    weak var delegate: OverlayServiceDelegate?

    /// Hooks into the profile store and settings to keep overlays up to date.
    init(profileStore: ProfileStore, appSettings: AppSettings) {
        self.profileStore = profileStore
        self.appSettings = appSettings
        overlayFiltersSubscription = appSettings.$overlayFiltersActive
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                self?.updateFilterActivationState(isEnabled)
            }
    }

    /// Turns overlay windows on or off and primes them with the latest style when becoming active.
    func setActive(_ isEnabled: Bool, animated: Bool) {
        guard areOverlaysActive != isEnabled else { return }
        areOverlaysActive = isEnabled
        if isEnabled {
            refreshDisplays(animated: false, shouldApplyStyles: false)
            overlayWindowsByDisplayID.values.forEach { overlayWindow in
                let displayID = overlayWindow.associatedDisplayID()
                let overlayStyle = profileStore.style(forDisplayID: displayID)
                overlayWindow.setFiltersEnabled(appSettings.overlayFiltersActive, animated: false)
                overlayWindow.prepareForPresentation()
                overlayWindow.orderFrontRegardless()
                overlayWindow.animatePresentation(duration: overlayStyle.animationDuration, animated: animated)
                overlayWindow.apply(style: overlayStyle, animated: animated)
            }
            menuBarWindowsByDisplayID.values.forEach { backdropWindow in
                let displayID = backdropWindow.associatedDisplayID()
                let overlayStyle = profileStore.style(forDisplayID: displayID)
                backdropWindow.setFiltersEnabled(appSettings.overlayFiltersActive, animated: false)
                backdropWindow.prepareForPresentation()
                backdropWindow.orderFrontRegardless()
                backdropWindow.animatePresentation(duration: overlayStyle.animationDuration, animated: animated)
                backdropWindow.apply(style: overlayStyle, animated: animated)
            }
        } else {
            overlayWindowsByDisplayID.values.forEach { $0.hide(animated: animated) }
            menuBarWindowsByDisplayID.values.forEach { $0.hide(animated: animated) }
        }
        delegate?.overlayService(self, didUpdateOverlays: overlayWindowsByDisplayID)
    }

    /// Reconciles overlay windows with the currently connected displays and updates their frames and styles.
    func refreshDisplays(animated: Bool, shouldApplyStyles: Bool = true) {
        let connectedScreens = NSScreen.screens
        var activeDisplayIDs = Set<DisplayID>()

        for screen in connectedScreens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = DisplayID(truncating: screenNumber)
            activeDisplayIDs.insert(displayID)

            if profileStore.isDisplayExcluded(displayID) {
                if let existing = overlayWindowsByDisplayID[displayID] {
                    existing.orderOut(nil)
                    overlayWindowsByDisplayID.removeValue(forKey: displayID)
                }
                if let backdrop = menuBarWindowsByDisplayID[displayID] {
                    backdrop.orderOut(nil)
                    menuBarWindowsByDisplayID.removeValue(forKey: displayID)
                }
                continue
            }

            if let overlayWindow = overlayWindowsByDisplayID[displayID] {
                overlayWindow.updateFrame(to: screen)
            } else {
                let overlayWindow = OverlayWindow(screen: screen, displayID: displayID)
                overlayWindow.setFiltersEnabled(appSettings.overlayFiltersActive, animated: false)
                overlayWindowsByDisplayID[displayID] = overlayWindow
                if areOverlaysActive {
                    overlayWindow.orderFrontRegardless()
                }
            }

            if let overlayWindow = overlayWindowsByDisplayID[displayID], areOverlaysActive, shouldApplyStyles {
                let overlayStyle = profileStore.style(forDisplayID: displayID)
                overlayWindow.apply(style: overlayStyle, animated: animated)
            }

            let screenFrame = screen.frame
            let visibleFrame = screen.visibleFrame
            let menuBarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)

            if menuBarHeight > 0 {
                if let backdropWindow = menuBarWindowsByDisplayID[displayID] {
                    backdropWindow.updateFrame(to: screen)
                } else {
                    let backdropWindow = MenuBarBackdropWindow(screen: screen, displayID: displayID)
                    backdropWindow.setFiltersEnabled(appSettings.overlayFiltersActive, animated: false)
                    menuBarWindowsByDisplayID[displayID] = backdropWindow
                    if areOverlaysActive {
                        backdropWindow.orderFrontRegardless()
                    }
                }

                if let backdropWindow = menuBarWindowsByDisplayID[displayID], areOverlaysActive, shouldApplyStyles {
                    let overlayStyle = profileStore.style(forDisplayID: displayID)
                    backdropWindow.apply(style: overlayStyle, animated: animated)
                }
            } else if let backdropWindow = menuBarWindowsByDisplayID.removeValue(forKey: displayID) {
                backdropWindow.orderOut(nil)
            }
        }

        profileStore.removeInvalidOverrides(validDisplayIDs: activeDisplayIDs)

        let disconnectedDisplayIDs = overlayWindowsByDisplayID.keys.filter { !activeDisplayIDs.contains($0) }
        for displayID in disconnectedDisplayIDs {
            overlayWindowsByDisplayID[displayID]?.orderOut(nil)
            overlayWindowsByDisplayID.removeValue(forKey: displayID)
            if let backdropWindow = menuBarWindowsByDisplayID.removeValue(forKey: displayID) {
                backdropWindow.orderOut(nil)
            }
        }

        delegate?.overlayService(self, didUpdateOverlays: overlayWindowsByDisplayID)
    }

    /// Reapplies the stored style for the specified display.
    func updateStyle(for displayID: DisplayID, animated: Bool) {
        guard areOverlaysActive else { return }
        let overlayStyle = profileStore.style(forDisplayID: displayID)
        overlayWindowsByDisplayID[displayID]?.apply(style: overlayStyle, animated: animated)
        menuBarWindowsByDisplayID[displayID]?.apply(style: overlayStyle, animated: animated)
    }

    /// Enables or disables blur/tint filters across all overlay windows.
    private func updateFilterActivationState(_ isEnabled: Bool) {
        let shouldAnimate = areOverlaysActive && isEnabled
        overlayWindowsByDisplayID.values.forEach { $0.setFiltersEnabled(isEnabled, animated: shouldAnimate) }
        menuBarWindowsByDisplayID.values.forEach { $0.setFiltersEnabled(isEnabled, animated: shouldAnimate) }
    }
}
