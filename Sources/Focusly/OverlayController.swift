// Permissions (TCC):
// - Accessibility: required to retrieve focused window frames.
// - App Store: feature category "system-wide overlays" is often review-sensitive.

import AppKit

/// Keeps OverlayWindow instances synchronized with the focused window and display configuration.
@MainActor
final class OverlayController {
    private let pollingInterval: TimeInterval = 0.2
    private let activeWindowSnapshotResolver: (Set<Int>) -> ActiveWindowSnapshot?

    private var overlayWindows: [DisplayID: OverlayWindow] = [:]
    private var screensByDisplayID: [DisplayID: NSScreen] = [:]
    private var pollingTimer: Timer?
    private var isClickThroughEnabled = true
    private var isRunning = false
    private var cachedActiveWindowSnapshot: ActiveWindowSnapshot?

    init(
        activeWindowSnapshotResolver: @escaping (Set<Int>) -> ActiveWindowSnapshot? = { windowNumbers in
            resolveActiveWindowSnapshot(excluding: windowNumbers)
        }
    ) {
        self.activeWindowSnapshotResolver = activeWindowSnapshotResolver
    }

    /// Begins monitoring the focused window and updates overlay masks accordingly.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        rebuildScreensLookup()
        startPolling()
        applyCachedOverlayMask()
        if cachedActiveWindowSnapshot == nil {
            refreshActiveWindowSnapshot()
        }
    }

    /// Stops monitoring and clears active overlay carve-outs.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopPolling()
        cachedActiveWindowSnapshot = nil
        overlayWindows.values.forEach { $0.applyMask(regions: []) }
    }

    /// Toggles whether overlay windows forward mouse events to windows underneath.
    func setClickThrough(_ enabled: Bool) {
        isClickThroughEnabled = enabled
        overlayWindows.values.forEach { $0.setClickThrough(enabled) }
    }

    /// Seeds the controller with an initial snapshot so overlays can immediately carve it out.
    func primeOverlayMask(with snapshot: ActiveWindowSnapshot?) {
        cachedActiveWindowSnapshot = snapshot
        if isRunning {
            applyCachedOverlayMask()
        }
    }

    /// Replaces the overlay window map, cleaning up removed displays and applying cached masks.
    func refreshOverlayWindows(_ updatedOverlayWindows: [DisplayID: OverlayWindow]) {
        let previousOverlayWindows = overlayWindows
        overlayWindows = updatedOverlayWindows
        rebuildScreensLookup()

        let removedDisplayIDs = Set(previousOverlayWindows.keys).subtracting(updatedOverlayWindows.keys)
        for displayID in removedDisplayIDs {
            previousOverlayWindows[displayID]?.applyMask(regions: [])
        }

        overlayWindows.values.forEach { $0.setClickThrough(isClickThroughEnabled) }

        if isRunning {
            applyCachedOverlayMask()
        }
    }

    /// Applies the supplied snapshot to all overlays, carving out the focused window and related UI.
    func applyOverlayMask(with snapshot: ActiveWindowSnapshot?) {
        cachedActiveWindowSnapshot = snapshot

        guard let snapshot else {
            overlayWindows.values.forEach { $0.applyMask(regions: []) }
            return
        }

        let activeFrame = snapshot.frame

        guard let targetDisplayID = screenIdentifier(for: activeFrame) else {
            overlayWindows.values.forEach { $0.applyMask(regions: []) }
            return
        }

        for (displayID, window) in overlayWindows {
            guard let contentView = window.contentView else {
                window.applyMask(regions: [])
                continue
            }

            if displayID == targetDisplayID {
                let windowRect = window.convertFromScreen(activeFrame)
                let rectInContent = contentView.convert(windowRect, from: nil)
                let normalizedRect = rectInContent.intersection(contentView.bounds)
                var maskRegions: [OverlayWindow.MaskRegion] = []

                if !normalizedRect.isNull {
                    maskRegions.append(OverlayWindow.MaskRegion(rect: normalizedRect, cornerRadius: snapshot.cornerRadius))
                }

                // Add any context menus or menu-bar popovers linked to the focused app.
                for supplementary in snapshot.supplementaryMasks {
                    let supplementaryWindowRect = window.convertFromScreen(supplementary.frame)
                    let supplementaryRectInContent = contentView.convert(supplementaryWindowRect, from: nil)
                    let normalizedSupplementary = supplementaryRectInContent.intersection(contentView.bounds)
                    guard !normalizedSupplementary.isNull else { continue }
                    maskRegions.append(OverlayWindow.MaskRegion(rect: normalizedSupplementary, cornerRadius: supplementary.cornerRadius))
                }

                window.applyMask(regions: maskRegions)
            } else {
                window.applyMask(regions: [])
            }
        }
    }

    /// Starts a repeating timer that samples the focused window position.
    private func startPolling() {
        pollingTimer = Timer.scheduledTimer(timeInterval: pollingInterval, target: self, selector: #selector(handlePollingTimer(_:)), userInfo: nil, repeats: true)
        if let pollingTimer {
            RunLoop.main.add(pollingTimer, forMode: .common)
        }
    }

    /// Stops the polling timer.
    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    /// Reapplies the last known snapshot so new overlay windows pick up current carve-outs.
    private func applyCachedOverlayMask() {
        applyOverlayMask(with: cachedActiveWindowSnapshot)
    }

    /// Resolves the active window snapshot and updates overlays when it changes.
    private func refreshActiveWindowSnapshot() {
        let snapshot = activeWindowSnapshotResolver(activeOverlayWindowNumbers())
        if let last = cachedActiveWindowSnapshot, let snapshot {
            guard last != snapshot else { return }
        } else if cachedActiveWindowSnapshot == nil, snapshot == nil {
            return
        }
        applyOverlayMask(with: snapshot)
    }

    /// Returns window numbers for overlays so they can be ignored when calculating focus.
    private func activeOverlayWindowNumbers() -> Set<Int> {
        Set(
            overlayWindows.values
                .map { $0.windowNumber }
                .filter { $0 != 0 }
        )
    }

    /// Timer callback that re-checks the focused window position.
    @objc private func handlePollingTimer(_ timer: Timer) {
        refreshActiveWindowSnapshot()
    }

    /// Rebuilds the mapping between display identifiers and `NSScreen` instances.
    private func rebuildScreensLookup() {
        var mapping: [DisplayID: NSScreen] = [:]
        let knownDisplays = Set(overlayWindows.keys)
        for screen in NSScreen.screens {
            guard let displayID = Self.displayIdentifier(for: screen) else { continue }
            guard knownDisplays.contains(displayID) else { continue }
            mapping[displayID] = screen
        }
        screensByDisplayID = mapping
    }

    /// Finds the display whose bounds overlap the given rect the most.
    private func screenIdentifier(for frame: NSRect) -> DisplayID? {
        var bestMatch: (DisplayID, CGFloat)?

        for (displayID, screen) in screensByDisplayID {
            let intersection = screen.frame.intersection(frame)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if let currentBest = bestMatch {
                if area > currentBest.1 {
                    bestMatch = (displayID, area)
                }
            } else {
                bestMatch = (displayID, area)
            }
        }

        return bestMatch?.0
    }

    /// Converts an `NSScreen` into a stable `DisplayID`.
    private static func displayIdentifier(for screen: NSScreen) -> DisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return DisplayID(truncating: number)
    }
}

extension OverlayController: OverlayServiceDelegate {
    /// Receives overlay updates from the service and replaces the managed window set.
    func overlayService(_ service: OverlayService, didUpdateOverlays updatedOverlayWindows: [DisplayID: OverlayWindow]) {
        refreshOverlayWindows(updatedOverlayWindows)
    }
}
