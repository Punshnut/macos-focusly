import AppKit
import CoreGraphics
import CoreImage
import QuartzCore

@MainActor
final class OverlayWindow: NSPanel {
    private let blurView = OverlayBlurView()

    private let captureContainer: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer = CALayer()
        view.layerUsesCoreImageFilters = true
        view.isHidden = true
        return view
    }()

    private let tintView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.systemIndigo.withAlphaComponent(0.08).cgColor
        return view
    }()

    private let maskLayer = CAShapeLayer()
    private var currentStyle: FocusOverlayStyle?
    private var currentMaskRectInContent: NSRect?
    private var captureView: NSView?
    private var currentBlurRadius: Double = 0
    private var blurRenderer: DisplayBlurRenderer?
    private var captureIsAvailable = false
    private(set) var displayID: DisplayID
    private weak var assignedScreen: NSScreen?

    init(screen: NSScreen, displayID: DisplayID) {
        self.displayID = displayID
        let frame = screen.frame
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = false
        hidesOnDeactivate = false
        worksWhenModal = true
        assignedScreen = screen
        configureWindow()
        configureContent()
        updateToScreenFrame()
    }

    convenience init(screen: NSScreen) {
        let displayID = OverlayWindow.resolveDisplayID(for: screen)
        self.init(screen: screen, displayID: displayID)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setClickThrough(_ enabled: Bool) {
        ignoresMouseEvents = enabled
    }

    func setTintColor(_ color: NSColor, alpha: CGFloat) {
        let clampedAlpha = max(0, min(alpha, 1))
        tintView.layer?.backgroundColor = color.withAlphaComponent(clampedAlpha).cgColor
    }

    func setTintAlpha(_ alpha: CGFloat) {
        let clampedAlpha = max(0, min(alpha, 1))
        guard let color = tintView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) else {
            // Default to system indigo if we somehow lost the color.
            setTintColor(.systemIndigo, alpha: clampedAlpha)
            return
        }
        tintView.layer?.backgroundColor = color.withAlphaComponent(clampedAlpha).cgColor
    }

    func setMaterial(_ material: NSVisualEffectView.Material) {
        blurView.setMaterial(material)
    }

    func applyMask(excluding rectInContentView: NSRect?) {
        guard let contentView else { return }

        if contentView.layer == nil {
            contentView.wantsLayer = true
            contentView.layer = CALayer()
        }

        if let rect = rectInContentView {
            let bounds = contentView.bounds
            if shouldIgnoreMask(rect: rect, in: bounds) {
                currentMaskRectInContent = nil
                contentView.layer?.mask = nil
                return
            }
            currentMaskRectInContent = rect
        } else {
            currentMaskRectInContent = nil
            contentView.layer?.mask = nil
            return
        }

        updateMaskLayer()
    }

    func setCaptureView(_ view: NSView?) {
        captureView?.removeFromSuperview()

        captureView = view

        guard let captureView else {
            captureContainer.isHidden = !captureIsAvailable
            blurView.isHidden = captureIsAvailable ? true : false
            applyBlurToCaptureView(radius: currentBlurRadius)
            return
        }

        captureView.translatesAutoresizingMaskIntoConstraints = false
        captureContainer.addSubview(captureView)
        NSLayoutConstraint.activate([
            captureView.leadingAnchor.constraint(equalTo: captureContainer.leadingAnchor),
            captureView.trailingAnchor.constraint(equalTo: captureContainer.trailingAnchor),
            captureView.topAnchor.constraint(equalTo: captureContainer.topAnchor),
            captureView.bottomAnchor.constraint(equalTo: captureContainer.bottomAnchor)
        ])

        captureContainer.isHidden = false
        blurView.isHidden = true
        captureIsAvailable = true
        applyBlurToCaptureView(radius: currentBlurRadius)
    }

    func updateToScreenFrame() {
        guard let targetScreen = assignedScreen ?? screen else { return }
        let frame = targetScreen.frame
        setFrame(frame, display: true)
        updateMaskLayer()
    }

    func setAssignedScreen(_ screen: NSScreen) {
        assignedScreen = screen
        updateToScreenFrame()
    }

    func associatedDisplayID() -> DisplayID {
        displayID
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            self?.updateBlurRendererWindowID()
            self?.startBlurCaptureIfNeeded()
        }
    }

    private func configureWindow() {
        let mainMenuLevel = CGWindowLevelForKey(.mainMenuWindow)
        level = NSWindow.Level(rawValue: Int(mainMenuLevel) - 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
    }

    private func configureContent() {
        guard let contentView else { return }
        contentView.wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = true
        contentView.autoresizingMask = [.width, .height]
        contentView.layer = CALayer()
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        contentView.addSubview(blurView)
        contentView.addSubview(captureContainer)
        contentView.addSubview(tintView)

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: contentView.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            captureContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            captureContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            captureContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            captureContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private static func resolveDisplayID(for screen: NSScreen) -> DisplayID {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return 0
        }
        return DisplayID(truncating: number)
    }

    func prepareForPresentation() {
        blurRenderer?.stop()
        alphaValue = 0
        tintView.layer?.removeAllAnimations()
        blurView.layer?.removeAllAnimations()
        contentView?.layer?.removeAllAnimations()
    }

    func hide(animated: Bool) {
        let duration = currentStyle?.animationDuration ?? 0.25
        blurRenderer?.stop()
        guard animated else {
            alphaValue = 0
            orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.completionHandler = { [weak self] in
                self?.orderOut(nil)
            }
            self.animator().alphaValue = 0
        }
    }

    func apply(style: FocusOverlayStyle, animated: Bool) {
        currentStyle = style
        let duration = style.animationDuration
        let targetOpacity = CGFloat(style.opacity)
        let targetColor = style.tint.makeColor()
        blurView.setColorTreatment(style.colorTreatment)
        blurRenderer?.setColorTreatment(style.colorTreatment)

        let applyValues = {
            self.alphaValue = targetOpacity
            self.tintView.layer?.backgroundColor = targetColor.cgColor
        }

        guard animated else {
            applyValues()
            updateBlurRadius(style.blurRadius, animated: false, duration: duration)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = targetOpacity
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        tintView.layer?.backgroundColor = targetColor.cgColor
        CATransaction.commit()

        updateBlurRadius(style.blurRadius, animated: true, duration: duration)
    }

    func updateFrame(to screen: NSScreen) {
        setAssignedScreen(screen)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        updateMaskLayer()
        blurRenderer?.updateScreenFrame(currentScreenFrame())
    }

    private func updateMaskLayer() {
        guard let contentView else { return }
        guard let contentLayer = contentView.layer else { return }

        guard let maskRect = currentMaskRectInContent else {
            contentLayer.mask = nil
            return
        }

        let path = CGMutablePath()
        path.addRect(contentView.bounds)
        path.addRect(maskRect)

        maskLayer.frame = contentView.bounds
        maskLayer.fillRule = .evenOdd
        maskLayer.path = path
        maskLayer.contentsScale = backingScaleFactor
        contentLayer.mask = maskLayer
    }

    private func startBlurCaptureIfNeeded() {
        configureBlurRendererIfPossible()
        blurRenderer?.setBlurRadius(currentBlurRadius)
        blurRenderer?.setColorTreatment(currentStyle?.colorTreatment ?? .preserveColor)
        blurRenderer?.start()
    }

    private func configureBlurRendererIfPossible() {
        if let renderer = blurRenderer {
            renderer.updateScreenFrame(currentScreenFrame())
            if let windowID = currentOverlayWindowID() {
                renderer.updateOverlayWindowID(windowID)
            }
            return
        }

        guard
            let layer = captureContainer.layer,
            let windowID = currentOverlayWindowID()
        else {
            return
        }

        let renderer = DisplayBlurRenderer(
            displayID: displayID,
            screenFrame: currentScreenFrame(),
            overlayWindowID: windowID,
            targetLayer: layer
        ) { [weak self] available in
            self?.handleBlurAvailabilityChange(isAvailable: available)
        }
        renderer.setBlurRadius(currentBlurRadius)
        renderer.setColorTreatment(currentStyle?.colorTreatment ?? .preserveColor)
        blurRenderer = renderer
    }

    private func updateBlurRendererWindowID() {
        configureBlurRendererIfPossible()
        if let windowID = currentOverlayWindowID() {
            blurRenderer?.updateOverlayWindowID(windowID)
        }
    }

    private func currentOverlayWindowID() -> CGWindowID? {
        let number = windowNumber
        guard number != 0 else { return nil }
        return CGWindowID(number)
    }

    private func currentScreenFrame() -> CGRect {
        if let assignedScreen {
            return assignedScreen.frame
        }
        if let windowScreen = screen {
            return windowScreen.frame
        }
        return frame
    }

    @MainActor
    private func handleBlurAvailabilityChange(isAvailable: Bool) {
        captureIsAvailable = isAvailable
        captureContainer.isHidden = !isAvailable
        blurView.isHidden = isAvailable
        if !isAvailable {
            captureContainer.layer?.contents = nil
        } else {
            let scale = assignedScreen?.backingScaleFactor ?? screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            captureContainer.layer?.contentsScale = scale
        }
    }

    private func updateBlurRadius(_ radius: Double, animated: Bool, duration: TimeInterval) {
        let clamped = max(0, min(radius, 100))
        let radiusChanged = abs(clamped - currentBlurRadius) > .ulpOfOne
        currentBlurRadius = clamped
        blurView.setBlurRadius(clamped, animated: animated && radiusChanged, duration: duration)
        blurRenderer?.setBlurRadius(clamped)
        applyBlurToCaptureView(radius: clamped)
    }

    private func applyBlurToCaptureView(radius: Double) {
        captureContainer.layer?.filters = nil
    }

    private func shouldIgnoreMask(rect: NSRect, in bounds: NSRect) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return true }
        let intersection = rect.intersection(bounds)
        guard !intersection.isNull else { return true }
        let coverage = (intersection.width * intersection.height) / (bounds.width * bounds.height)
        return coverage >= 0.98
    }
}

private final class OverlayBlurView: NSView {
    private let blurFilter = CIFilter(name: "CIGaussianBlur")
    private let desaturateFilter = CIFilter(name: "CIColorControls")
    private var material: NSVisualEffectView.Material = .hudWindow
    private var colorTreatment: FocusOverlayColorTreatment = .preserveColor
    private var blurRadius: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerUsesCoreImageFilters = true
        blurFilter?.setDefaults()
        desaturateFilter?.setDefaults()
        desaturateFilter?.setValue(0, forKey: kCIInputSaturationKey)

        if let backdropLayerType = NSClassFromString("CABackdropLayer") as? CALayer.Type {
            let layer = backdropLayerType.init()
            layer.backgroundColor = NSColor.clear.cgColor
            layer.isOpaque = false
            layer.masksToBounds = true
            layer.needsDisplayOnBoundsChange = true
            if #available(macOS 12.0, *) {
                layer.cornerCurve = .continuous
            }
            self.layer = layer
        } else {
            let layer = CALayer()
            layer.backgroundColor = NSColor.clear.cgColor
            layer.isOpaque = false
            layer.masksToBounds = true
            if #available(macOS 12.0, *) {
                layer.cornerCurve = .continuous
            }
            self.layer = layer
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setMaterial(_ material: NSVisualEffectView.Material) {
        self.material = material
        // Placeholder for future differentiation between materials.
        // Currently the Gaussian blur handles the heavy lifting.
    }

    func setBlurRadius(_ radius: Double, animated: Bool, duration: TimeInterval) {
        guard let layer else { return }

        let clampedRadius = max(0, radius)
        blurRadius = clampedRadius
        if let blurFilter {
            blurFilter.setValue(clampedRadius, forKey: kCIInputRadiusKey)
        }

        applyFilters(on: layer, animated: animated, duration: duration)
    }

    func setColorTreatment(_ treatment: FocusOverlayColorTreatment) {
        guard colorTreatment != treatment, let layer else {
            colorTreatment = treatment
            return
        }
        colorTreatment = treatment
        applyFilters(on: layer, animated: false, duration: 0)
    }

    private func applyFilters(on layer: CALayer, animated: Bool, duration: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        var filters: [CIFilter] = []
        if blurRadius > 0, let blurFilter {
            filters.append(blurFilter)
        }
        if colorTreatment == .monochrome, let desaturateFilter {
            desaturateFilter.setValue(0, forKey: kCIInputSaturationKey)
            filters.append(desaturateFilter)
        }
        let appliedFilters: [CIFilter]? = filters.isEmpty ? nil : filters
        layer.backgroundFilters = appliedFilters
        layer.filters = appliedFilters
        CATransaction.commit()
    }
}
