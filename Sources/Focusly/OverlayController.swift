// Permissions (TCC):
// - Accessibility: required to retrieve focused window frames.
// - App Store: feature category "system-wide overlays" is often review-sensitive.

import AppKit

@MainActor
final class OverlayController {
    private let pollInterval: TimeInterval = 0.2
    private let activeWindowSnapshotProvider: (Set<Int>) -> ActiveWindowSnapshot?

    private var overlays: [DisplayID: OverlayWindow] = [:]
    private var screensByID: [DisplayID: NSScreen] = [:]
    private var pollTimer: Timer?
    private var clickThroughEnabled = true
    private var isRunning = false
    private var lastActiveWindowSnapshot: ActiveWindowSnapshot?

    init(
        activeWindowSnapshotProvider: @escaping (Set<Int>) -> ActiveWindowSnapshot? = resolveActiveWindowSnapshot
    ) {
        self.activeWindowSnapshotProvider = activeWindowSnapshotProvider
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        rebuildScreensLookup()
        startPolling()
        applyCurrentHole()
        pollActiveWindowSnapshot()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopPolling()
        lastActiveWindowSnapshot = nil
        overlays.values.forEach { $0.applyMask(regions: []) }
    }

    func setClickThrough(_ enabled: Bool) {
        clickThroughEnabled = enabled
        overlays.values.forEach { $0.setClickThrough(enabled) }
    }

    func updateOverlays(_ newOverlays: [DisplayID: OverlayWindow]) {
        let previous = overlays
        overlays = newOverlays
        rebuildScreensLookup()

        let removedIDs = Set(previous.keys).subtracting(newOverlays.keys)
        for id in removedIDs {
            previous[id]?.applyMask(regions: [])
        }

        overlays.values.forEach { $0.setClickThrough(clickThroughEnabled) }

        if isRunning {
            applyCurrentHole()
        }
    }

    func updateHole(with snapshot: ActiveWindowSnapshot?) {
        lastActiveWindowSnapshot = snapshot

        guard let snapshot else {
            overlays.values.forEach { $0.applyMask(regions: []) }
            return
        }

        let frame = snapshot.frame

        guard let targetDisplayID = screenIdentifier(for: frame) else {
            overlays.values.forEach { $0.applyMask(regions: []) }
            return
        }

        for (displayID, window) in overlays {
            guard let contentView = window.contentView else {
                window.applyMask(regions: [])
                continue
            }

            if displayID == targetDisplayID {
                let windowRect = window.convertFromScreen(frame)
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

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(timeInterval: pollInterval, target: self, selector: #selector(handlePollTimer(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func applyCurrentHole() {
        updateHole(with: lastActiveWindowSnapshot)
    }

    private func pollActiveWindowSnapshot() {
        let snapshot = activeWindowSnapshotProvider(currentOverlayWindowNumbers())
        if let last = lastActiveWindowSnapshot, let snapshot {
            guard last != snapshot else { return }
        } else if lastActiveWindowSnapshot == nil, snapshot == nil {
            return
        }
        updateHole(with: snapshot)
    }

    private func currentOverlayWindowNumbers() -> Set<Int> {
        Set(
            overlays.values
                .map { $0.windowNumber }
                .filter { $0 != 0 }
        )
    }

    @objc private func handlePollTimer(_ timer: Timer) {
        pollActiveWindowSnapshot()
    }

    private func rebuildScreensLookup() {
        var mapping: [DisplayID: NSScreen] = [:]
        let knownDisplays = Set(overlays.keys)
        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(for: screen) else { continue }
            guard knownDisplays.contains(displayID) else { continue }
            mapping[displayID] = screen
        }
        screensByID = mapping
    }

    private func screenIdentifier(for frame: NSRect) -> DisplayID? {
        var bestMatch: (DisplayID, CGFloat)?

        for (displayID, screen) in screensByID {
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

    private static func displayID(for screen: NSScreen) -> DisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return DisplayID(truncating: number)
    }
}

extension OverlayController: OverlayServiceDelegate {
    func overlayService(_ service: OverlayService, didUpdateOverlays overlays: [DisplayID: OverlayWindow]) {
        updateOverlays(overlays)
    }
}
