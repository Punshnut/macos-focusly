import AppKit
import Foundation
import CoreGraphics
import CoreImage

/// Captures the pixels beneath an overlay window, applies Gaussian blur and optional treatments,
/// then streams the result into the overlay's backing layer.
final class DisplayBlurRenderer {
    typealias AvailabilityHandler = @MainActor (Bool) -> Void

    private let displayID: DisplayID
    private var overlayWindowID: CGWindowID
    private weak var targetLayer: CALayer?
    private var screenFrame: CGRect
    private var blurRadius: Double = 0
    private var colorTreatment: FocusOverlayColorTreatment = .preserveColor
    private var timer: DispatchSourceTimer?
    private let queue: DispatchQueue
    private let ciContext: CIContext
    private var isRunning = false
    private var availabilityHandler: (Bool) -> Void
    private var captureAvailable = false
    private let blurFilter = CIFilter(name: "CIGaussianBlur")
    private let monochromeFilter = CIFilter(name: "CIColorControls")
    private let captureInterval: TimeInterval = 1.0 / 15.0

    init(
        displayID: DisplayID,
        screenFrame: CGRect,
        overlayWindowID: CGWindowID,
        targetLayer: CALayer,
        availabilityChanged: @escaping AvailabilityHandler
    ) {
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.overlayWindowID = overlayWindowID
        self.targetLayer = targetLayer
        self.availabilityHandler = { available in
            Task { @MainActor in
                availabilityChanged(available)
            }
        }
        self.queue = DispatchQueue(label: "Focusly.DisplayBlurRenderer.\(displayID)", qos: .userInteractive)
        self.ciContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: NSNull()
        ])

        targetLayer.contentsGravity = .resize
        targetLayer.masksToBounds = true

        monochromeFilter?.setDefaults()
        monochromeFilter?.setValue(0, forKey: kCIInputSaturationKey)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        scheduleTimerIfNeeded()
        queue.async { [weak self] in
            self?.captureFrame()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
    }

    func updateOverlayWindowID(_ windowID: CGWindowID) {
        overlayWindowID = windowID
    }

    func updateScreenFrame(_ frame: CGRect) {
        screenFrame = frame
    }

    func setBlurRadius(_ radius: Double) {
        blurRadius = max(0, radius)
    }

    func setColorTreatment(_ treatment: FocusOverlayColorTreatment) {
        colorTreatment = treatment
    }

    private func scheduleTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: captureInterval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.captureFrame()
        }
        timer.resume()
        self.timer = timer
    }

    private func captureFrame() {
        guard isRunning else { return }
        guard let targetLayer else { return }

        guard overlayWindowID != 0 else {
            updateAvailability(false)
            return
        }

        guard let snapshot = CGWindowListCreateImage(
            screenFrame,
            [.optionOnScreenBelowWindow, .excludeDesktopElements],
            overlayWindowID,
            .bestResolution
        ) else {
            updateAvailability(false)
            return
        }

        var image = CIImage(cgImage: snapshot)

        // Translate so the extent starts at the origin for layer consumption.
        let extent = image.extent
        if extent.origin.x != 0 || extent.origin.y != 0 {
            image = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
        }

        image = applyFilters(to: image, originalExtent: CGRect(origin: .zero, size: extent.size))

        guard let output = ciContext.createCGImage(image, from: CGRect(origin: .zero, size: extent.size)) else {
            updateAvailability(false)
            return
        }

        updateAvailability(true)
        DispatchQueue.main.async {
            targetLayer.contents = output
            targetLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        }
    }

    private func applyFilters(to image: CIImage, originalExtent: CGRect) -> CIImage {
        var workingImage = image

        if blurRadius > 0.01, let blurFilter {
            blurFilter.setValue(workingImage.clampedToExtent(), forKey: kCIInputImageKey)
            blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
            if let blurred = blurFilter.outputImage?.cropped(to: originalExtent) {
                workingImage = blurred
            }
        }

        if colorTreatment == .monochrome, let mono = monochromeFilter {
            mono.setValue(workingImage, forKey: kCIInputImageKey)
            if let desaturated = mono.outputImage {
                workingImage = desaturated
            }
        }

        return workingImage
    }

    private func updateAvailability(_ available: Bool) {
        guard captureAvailable != available else { return }
        captureAvailable = available
        availabilityHandler(available)
    }
}
