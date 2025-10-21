import AppKit

@MainActor
final class OverlayService {
    private let profileStore: ProfileStore
    private var overlays: [DisplayID: OverlayWindow] = [:]
    private var enabled = false

    init(profileStore: ProfileStore) {
        self.profileStore = profileStore
    }

    func setEnabled(_ enabled: Bool, animated: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            refreshDisplays(animated: false, applyStyles: false)
            overlays.values.forEach { overlay in
                overlay.prepareForPresentation()
                overlay.orderFrontRegardless()
                let style = profileStore.style(forDisplayID: overlay.associatedDisplayID())
                overlay.apply(style: style, animated: animated)
            }
        } else {
            overlays.values.forEach { $0.hide(animated: animated) }
        }
    }

    func refreshDisplays(animated: Bool, applyStyles: Bool = true) {
        let screens = NSScreen.screens
        var seenIDs = Set<DisplayID>()

        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = DisplayID(truncating: number)
            seenIDs.insert(displayID)

            if let overlay = overlays[displayID] {
                overlay.updateFrame(to: screen)
            } else {
                let overlay = OverlayWindow(screen: screen, screenID: displayID)
                overlays[displayID] = overlay
                if enabled {
                    overlay.orderFrontRegardless()
                }
            }

            if let overlay = overlays[displayID], enabled, applyStyles {
                let style = profileStore.style(forDisplayID: displayID)
                overlay.apply(style: style, animated: animated)
            }
        }

        profileStore.removeInvalidOverrides(validDisplayIDs: seenIDs)

        let staleKeys = overlays.keys.filter { !seenIDs.contains($0) }
        for key in staleKeys {
            overlays[key]?.orderOut(nil)
            overlays.removeValue(forKey: key)
        }
    }

    func updateStyle(for displayID: DisplayID, animated: Bool) {
        guard let overlay = overlays[displayID], enabled else { return }
        overlay.apply(style: profileStore.style(forDisplayID: displayID), animated: animated)
    }
}
