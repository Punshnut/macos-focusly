// Permissions (TCC):
// - Accessibility: required to retrieve focused window frames.
// - App Store: feature category "system-wide overlays" is often review-sensitive.

import AppKit

@MainActor
final class OverlayController {
    private let pollInterval: TimeInterval = 0.2
    private let activeWindowFrameProvider: () -> NSRect?

    private var overlays: [DisplayID: OverlayWindow] = [:]
    private var screensByID: [DisplayID: NSScreen] = [:]
    private var pollTimer: Timer?
    private var tintColor: NSColor = .systemIndigo
    private var tintAlpha: CGFloat = 0.08
    private var material: NSVisualEffectView.Material = .hudWindow
    private var clickThroughEnabled = true
    private var isRunning = false
    private var lastActiveWindowFrame: NSRect?

    init(activeWindowFrameProvider: @escaping () -> NSRect? = axActiveWindowFrame) {
        self.activeWindowFrameProvider = activeWindowFrameProvider
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshScreens()
        bringOverlaysToFront()
        startPolling()
        pollActiveWindowFrame()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopPolling()
        lastActiveWindowFrame = nil
        overlays.values.forEach { window in
            window.applyMask(excluding: nil)
            window.orderOut(nil)
        }
    }

    func setTintColor(_ color: NSColor, alpha: CGFloat) {
        tintColor = color
        tintAlpha = alpha
        overlays.values.forEach { $0.setTintColor(color, alpha: alpha) }
    }

    func setTintAlpha(_ alpha: CGFloat) {
        tintAlpha = alpha
        overlays.values.forEach { $0.setTintAlpha(alpha) }
    }

    func setMaterial(_ material: NSVisualEffectView.Material) {
        self.material = material
        overlays.values.forEach { $0.setMaterial(material) }
    }

    func setClickThrough(_ enabled: Bool) {
        clickThroughEnabled = enabled
        overlays.values.forEach { $0.setClickThrough(enabled) }
    }

    func refreshScreens() {
        var seenIDs = Set<DisplayID>()

        for screen in NSScreen.screens {
            guard let displayID = Self.displayID(for: screen) else { continue }
            seenIDs.insert(displayID)
            screensByID[displayID] = screen

            if let window = overlays[displayID] {
                window.setAssignedScreen(screen)
                window.updateToScreenFrame()
            } else {
                let window = OverlayWindow(screen: screen, displayID: displayID)
                window.setTintColor(tintColor, alpha: tintAlpha)
                window.setMaterial(material)
                window.setClickThrough(clickThroughEnabled)
                overlays[displayID] = window
                if isRunning {
                    window.orderFrontRegardless()
                }
            }

            overlays[displayID]?.setCaptureView(nil)
        }

        let staleIDs = overlays.keys.filter { !seenIDs.contains($0) }
        for displayID in staleIDs {
            overlays[displayID]?.orderOut(nil)
            overlays.removeValue(forKey: displayID)
            screensByID.removeValue(forKey: displayID)
        }

        applyCurrentHole()
    }

    func updateHole(forActiveWindowFrame frame: NSRect?) {
        lastActiveWindowFrame = frame

        guard let frame else {
            overlays.values.forEach { $0.applyMask(excluding: nil) }
            return
        }

        guard let targetDisplayID = screenIdentifier(for: frame) else {
            overlays.values.forEach { $0.applyMask(excluding: nil) }
            return
        }

        for (displayID, window) in overlays {
            guard let contentView = window.contentView else {
                window.applyMask(excluding: nil)
                continue
            }

            if displayID == targetDisplayID {
                let windowRect = window.convertFromScreen(frame)
                let rectInContent = contentView.convert(windowRect, from: nil)
                let normalizedRect = rectInContent.intersection(contentView.bounds)
                window.applyMask(excluding: normalizedRect.isNull ? nil : normalizedRect)
            } else {
                window.applyMask(excluding: nil)
            }
        }
    }

    private func bringOverlaysToFront() {
        overlays.values.forEach { $0.orderFrontRegardless() }
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
        updateHole(forActiveWindowFrame: lastActiveWindowFrame)
    }

    private func pollActiveWindowFrame() {
        let frame = activeWindowFrameProvider()
        if let last = lastActiveWindowFrame, let frame {
            guard !NSEqualRects(last, frame) else { return }
        } else if lastActiveWindowFrame == nil, frame == nil {
            return
        }
        updateHole(forActiveWindowFrame: frame)
    }

    @objc private func handlePollTimer(_ timer: Timer) {
        pollActiveWindowFrame()
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
