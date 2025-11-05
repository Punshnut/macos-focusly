import AppKit
import QuartzCore
import CoreImage

/// Full-screen, click-through panel that renders Focusly's blur and tint overlay above a display.
@MainActor
final class OverlayWindow: NSPanel {
    private let blurEffectView = OverlayBlurView()

    /// Represents a transparent region that should be carved out of the overlay.
    struct MaskRegion: Equatable {
        let rect: NSRect
        let cornerRadius: CGFloat
    }

    /// Semi-transparent tint view that sits on top of the blur to colorize the overlay.
    private let tintOverlayView: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        let layer = CALayer()
        layer.backgroundColor = NSColor.systemIndigo.withAlphaComponent(0.08).cgColor
        layer.isOpaque = false
        view.layer = layer
        return view
    }()

    private let tintMaskingLayer = OverlayMaskLayer()
    private let blurMaskingLayer = OverlayMaskLayer()
    private var activeStyle: FocusOverlayStyle?
    private var activeMaskRegions: [MaskRegion] = []
    private var staticExclusionRects: [NSRect] = []
    private(set) var displayIdentifier: DisplayID
    private weak var attachedScreen: NSScreen?
    /// Toggles whether the blur/tint pipeline is applied or bypassed entirely.
    private var filtersAreActive = true {
        didSet {
            guard filtersAreActive != oldValue else { return }
            blurEffectView.setBlurEnabled(filtersAreActive)
            tintOverlayView.isHidden = !filtersAreActive
            if filtersAreActive {
                refreshMaskLayers()
            } else {
                resetMaskLayers(preserveActiveRegions: true)
            }
        }
    }

    /// Creates a new overlay window that is pinned to the given screen and display identifier.
    init(screen: NSScreen, displayIdentifier: DisplayID) {
        self.displayIdentifier = displayIdentifier
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
        attachedScreen = screen
        configureWindow()
        configureContent()
        updateToScreenFrame()
    }

    /// Convenience initializer that derives the display identifier from the screen.
    convenience init(screen: NSScreen) {
        let displayIdentifier = OverlayWindow.resolveDisplayIdentifier(for: screen)
        self.init(screen: screen, displayIdentifier: displayIdentifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Enables or disables pass-through mouse handling so the overlay does not consume events.
    func setClickThrough(_ enabled: Bool) {
        ignoresMouseEvents = enabled
    }

    /// Updates the overlay tint to the given color/alpha combination.
    func setTintColor(_ color: NSColor, alpha: CGFloat) {
        let clampedAlpha = max(0, min(alpha, 1))
        tintOverlayView.layer?.backgroundColor = color.withAlphaComponent(clampedAlpha).cgColor
    }

    /// Adjusts the tint opacity while preserving the existing color.
    func setTintAlpha(_ alpha: CGFloat) {
        let clampedAlpha = max(0, min(alpha, 1))
        guard let color = tintOverlayView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) else {
            setTintColor(.systemIndigo, alpha: clampedAlpha)
            return
        }
        tintOverlayView.layer?.backgroundColor = color.withAlphaComponent(clampedAlpha).cgColor
    }

    /// Toggles whether blur/tint effects should be active.
    func setFiltersEnabled(_ enabled: Bool) {
        filtersAreActive = enabled
    }

    /// Updates the underlying `NSVisualEffectView` material used for blurring.
    func setMaterial(_ material: NSVisualEffectView.Material) {
        blurEffectView.material = material
    }

    /// Applies a single carved-out mask region, typically matching a focused window.
    func applyMask(excluding rectInContentView: NSRect?, cornerRadius: CGFloat = 0) {
        if let rect = rectInContentView {
            applyMask(regions: [MaskRegion(rect: rect, cornerRadius: cornerRadius)])
        } else {
            applyMask(regions: [])
        }
    }

    /// Applies multiple carved-out regions so windows, menus, and other UI remain visible.
    func applyMask(regions: [MaskRegion]) {
        guard let contentView else { return }

        let bounds = contentView.bounds
        let tolerance = maskTolerance(for: contentView)

        let sanitized = regions.compactMap { region -> MaskRegion? in
            let clipped = region.rect.intersection(bounds)
            guard !clipped.isNull else { return nil }
            if shouldIgnoreMask(rect: clipped, in: bounds) { return nil }
            let limitedRadius = min(max(0, region.cornerRadius), min(clipped.width, clipped.height) / 2)
            return MaskRegion(rect: clipped, cornerRadius: limitedRadius)
        }

        // Keep a deterministic ordering so tolerance-based equality checks remain stable.
        let ordered = sanitized.sorted { lhs, rhs in
            if lhs.rect.origin.y != rhs.rect.origin.y {
                return lhs.rect.origin.y < rhs.rect.origin.y
            }
            if lhs.rect.origin.x != rhs.rect.origin.x {
                return lhs.rect.origin.x < rhs.rect.origin.x
            }
            if lhs.rect.width != rhs.rect.width {
                return lhs.rect.width < rhs.rect.width
            }
            return lhs.rect.height < rhs.rect.height
        }

        guard !ordered.isEmpty else {
            if activeMaskRegions.isEmpty {
                refreshMaskLayers()
                return
            }
            activeMaskRegions = []
            refreshMaskLayers()
            return
        }

        if activeMaskRegions.count == ordered.count {
            let matches = zip(activeMaskRegions, ordered).allSatisfy { current, updated in
                current.rect.isApproximatelyEqual(to: updated.rect, tolerance: tolerance) &&
                abs(current.cornerRadius - updated.cornerRadius) <= tolerance
            }
            if matches {
                return
            }
        }

        activeMaskRegions = ordered
        refreshMaskLayers()
    }

    /// Resizes the window to match the bounds of the current target screen.
    func updateToScreenFrame() {
        guard let targetScreen = attachedScreen ?? screen else { return }
        setFrame(targetScreen.frame, display: true)
    }

    /// Changes the screen the overlay is attached to and resizes accordingly.
    func setAttachedScreen(_ screen: NSScreen) {
        attachedScreen = screen
        updateToScreenFrame()
    }

    /// Returns the cached CoreGraphics display identifier used to map back to a screen.
    func associatedDisplayIdentifier() -> DisplayID {
        displayIdentifier
    }

    /// Keeps the overlay visible even if the app is not active.
    override func orderFrontRegardless() {
        super.orderFrontRegardless()
    }

    /// Configures window-level properties so the overlay behaves as a non-interactive panel.
    private func configureWindow() {
        level = .screenSaver
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

    /// Sets up the content view graph with the blur layer and tint layer stacked together.
    private func configureContent() {
        guard let contentView else { return }
        contentView.translatesAutoresizingMaskIntoConstraints = true
        contentView.autoresizingMask = [.width, .height]

        contentView.addSubview(blurEffectView)
        contentView.addSubview(tintOverlayView)

        NSLayoutConstraint.activate([
            blurEffectView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            blurEffectView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            blurEffectView.topAnchor.constraint(equalTo: contentView.topAnchor),
            blurEffectView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            tintOverlayView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tintOverlayView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tintOverlayView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tintOverlayView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    /// Resolves a display identifier from an `NSScreen` so the overlay can be restored later.
    private static func resolveDisplayIdentifier(for screen: NSScreen) -> DisplayID {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return 0
        }
        return DisplayID(truncating: number)
    }

    /// Resets transient state before showing the overlay.
    func prepareForPresentation() {
        alphaValue = 0
        tintOverlayView.layer?.removeAllAnimations()
        blurEffectView.prepareForReuse()
        contentView?.layer?.removeAllAnimations()
        if let targetScreen = attachedScreen ?? screen {
            recalculateStaticExclusions(for: targetScreen)
        }
        refreshMaskLayers()
    }

    /// Hides the overlay, optionally animating the fade-out.
    func hide(animated: Bool) {
        let duration = activeStyle?.animationDuration ?? 0.25
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

    /// Applies the supplied overlay style, optionally animating opacity and colors.
    func apply(style: FocusOverlayStyle, animated: Bool) {
        activeStyle = style
        let duration = style.animationDuration
        let targetOpacity = CGFloat(max(0, min(style.opacity, 1)))
        let targetColor = style.tint.makeColor()

        let applyValues = {
            if self.alphaValue != 1 {
                self.alphaValue = 1
            }
            self.blurEffectView.alphaValue = targetOpacity
            self.tintOverlayView.alphaValue = targetOpacity
            self.tintOverlayView.layer?.backgroundColor = targetColor.cgColor
        }

        blurEffectView.setExtraBlurRadius(CGFloat(max(0, style.blurRadius)))
        blurEffectView.setColorTreatment(style.colorTreatment)

        guard animated else {
            applyValues()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if self.alphaValue != 1 {
                self.animator().alphaValue = 1
            }
            self.blurEffectView.animator().alphaValue = targetOpacity
            self.tintOverlayView.animator().alphaValue = targetOpacity
        }

        // Rebuild the mask layer graph using destinationOut sublayers so overlaps stay transparent.
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        tintOverlayView.layer?.backgroundColor = targetColor.cgColor
        CATransaction.commit()
    }

    /// Re-associates the overlay with a different screen while keeping geometry in sync.
    func updateFrame(to screen: NSScreen) {
        setAttachedScreen(screen)
    }

    /// Keeps static exclusions in sync whenever the window's frame changes.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        if let targetScreen = attachedScreen ?? screen {
            recalculateStaticExclusions(for: targetScreen)
        } else {
            staticExclusionRects = []
        }
        refreshMaskLayers()
    }

    /// Calculates static exclusions such as the menu bar so they stay transparent.
    private func recalculateStaticExclusions(for screen: NSScreen) {
        guard let contentView else {
            staticExclusionRects = []
            return
        }

        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)

        guard menuBarHeight > 0 else {
            staticExclusionRects = []
            return
        }

        let menuBarRectInScreen = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - menuBarHeight,
            width: screenFrame.width,
            height: menuBarHeight
        )

        let menuBarRectInWindow = convertFromScreen(menuBarRectInScreen)
        let rectInContent = contentView.convert(menuBarRectInWindow, from: nil)
        staticExclusionRects = [rectInContent]
    }

    /// Updates CALayer masks to reflect the latest static and dynamic carve-outs.
    private func refreshMaskLayers() {
        guard let contentView else { return }
        guard filtersAreActive else {
            resetMaskLayers(preserveActiveRegions: true)
            return
        }

        let bounds = contentView.bounds
        let hasDynamicMask = !activeMaskRegions.isEmpty
        guard hasDynamicMask || !staticExclusionRects.isEmpty else {
            resetMaskLayers()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let scale = backingScaleFactor
        tintMaskingLayer.configure(
            bounds: bounds,
            scale: scale,
            staticRects: staticExclusionRects,
            dynamicRegions: activeMaskRegions
        )
        blurMaskingLayer.configure(
            bounds: bounds,
            scale: scale,
            staticRects: staticExclusionRects,
            dynamicRegions: activeMaskRegions
        )

        if tintOverlayView.layer?.mask !== tintMaskingLayer {
            tintOverlayView.layer?.mask = tintMaskingLayer
        }
        if blurEffectView.layer?.mask !== blurMaskingLayer {
            blurEffectView.layer?.mask = blurMaskingLayer
        }

        CATransaction.commit()
    }

    /// Clears active masks and releases mask images.
    private func resetMaskLayers(preserveActiveRegions: Bool = false) {
        tintOverlayView.layer?.mask = nil
        blurEffectView.layer?.mask = nil
        tintMaskingLayer.reset()
        blurMaskingLayer.reset()
        if !preserveActiveRegions {
            activeMaskRegions = []
        }
    }

    /// Determines whether a given rect should be ignored because it covers most of the overlay.
    private func shouldIgnoreMask(rect: NSRect, in bounds: NSRect) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return true }
        let intersection = rect.intersection(bounds)
        guard !intersection.isNull else { return true }
        let coverage = (intersection.width * intersection.height) / (bounds.width * bounds.height)
        return coverage >= 0.98
    }

    /// Returns the tolerance used when comparing mask rects, accounting for display scale.
    private func maskTolerance(for view: NSView) -> CGFloat {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return max(1.0 / max(scale, 1), 0.25)
    }
}

/// Mask layer that uses a fast vector path when carve-outs are disjoint and falls back to bitmap rasterization when regions overlap.
private final class OverlayMaskLayer: CALayer {
    private enum RenderingMode {
        case none
        case vector
        case bitmap
    }

    private struct HoleRegion {
        var rect: CGRect
        var cornerRadius: CGFloat
    }

    private let vectorMaskLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.anchorPoint = .zero
        layer.fillRule = .evenOdd
        layer.fillColor = NSColor.white.cgColor
        layer.actions = [
            "path": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        return layer
    }()

    private let bitmapMaskLayer: CALayer = {
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        layer.contentsGravity = .resize
        return layer
    }()

    private var renderingMode: RenderingMode = .none

    override init() {
        super.init()
        configureLayerHierarchy()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        configureLayerHierarchy()
    }

    private func configureLayerHierarchy() {
        anchorPoint = .zero
        backgroundColor = nil
        masksToBounds = false
        actions = [
            "bounds": NSNull(),
            "position": NSNull()
        ]
        sublayers?.forEach { $0.removeFromSuperlayer() }
        addSublayer(vectorMaskLayer)
        addSublayer(bitmapMaskLayer)
        vectorMaskLayer.isHidden = true
        bitmapMaskLayer.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Updates the mask to carve out the supplied static and dynamic regions.
    func configure(
        bounds: CGRect,
        scale: CGFloat,
        staticRects: [CGRect],
        dynamicRegions: [OverlayWindow.MaskRegion]
    ) {
        guard bounds.width > 0, bounds.height > 0 else {
            reset()
            return
        }

        let resolvedScale = max(scale, 1)
        frame = bounds
        contentsScale = resolvedScale
        vectorMaskLayer.frame = bounds
        vectorMaskLayer.contentsScale = resolvedScale
        bitmapMaskLayer.frame = bounds
        bitmapMaskLayer.contentsScale = resolvedScale

        let tolerance = max(1.0 / resolvedScale, 0.1)
        var holeRegions: [HoleRegion] = []
        holeRegions.reserveCapacity(staticRects.count + dynamicRegions.count)

        for rect in staticRects where rect.width > 0 && rect.height > 0 {
            appendHole(
                HoleRegion(rect: rect, cornerRadius: 0),
                to: &holeRegions,
                tolerance: tolerance
            )
        }

        for region in dynamicRegions {
            let rect = region.rect
            guard rect.width > 0, rect.height > 0 else { continue }
            let radius = min(max(region.cornerRadius, 0), min(rect.width, rect.height) / 2)
            appendHole(
                HoleRegion(rect: rect, cornerRadius: radius),
                to: &holeRegions,
                tolerance: tolerance
            )
        }

        guard !holeRegions.isEmpty else {
            reset()
            return
        }

        if holesOverlap(holeRegions, tolerance: tolerance) {
            applyBitmapMask(bounds: bounds, scale: resolvedScale, holes: holeRegions)
        } else {
            applyVectorMask(bounds: bounds, scale: resolvedScale, holes: holeRegions)
        }
    }

    /// Releases active masks so the overlay can revert to a solid fill.
    func reset() {
        bitmapMaskLayer.contents = nil
        bitmapMaskLayer.isHidden = true
        vectorMaskLayer.path = nil
        vectorMaskLayer.isHidden = true
        frame = .zero
        renderingMode = .none
    }

    private func appendHole(
        _ candidate: HoleRegion,
        to holes: inout [HoleRegion],
        tolerance: CGFloat
    ) {
        if let index = holes.firstIndex(where: {
            NSRect(
                x: $0.rect.origin.x,
                y: $0.rect.origin.y,
                width: $0.rect.width,
                height: $0.rect.height
            ).isApproximatelyEqual(
                to: NSRect(
                    x: candidate.rect.origin.x,
                    y: candidate.rect.origin.y,
                    width: candidate.rect.width,
                    height: candidate.rect.height
                ),
                tolerance: tolerance
            )
        }) {
            holes[index].cornerRadius = max(holes[index].cornerRadius, candidate.cornerRadius)
        } else {
            holes.append(candidate)
        }
    }

    private func holesOverlap(_ holes: [HoleRegion], tolerance: CGFloat) -> Bool {
        guard holes.count > 1 else { return false }
        for index in 0..<(holes.count - 1) {
            let first = holes[index].rect
            for comparisonIndex in (index + 1)..<holes.count {
                let second = holes[comparisonIndex].rect
                let intersection = first.intersection(second)
                guard !intersection.isNull else { continue }
                if (intersection.width * intersection.height) > tolerance {
                    return true
                }
            }
        }
        return false
    }

    private func applyVectorMask(bounds: CGRect, scale: CGFloat, holes: [HoleRegion]) {
        guard let path = makeVectorMaskPath(bounds: bounds, scale: scale, holes: holes) else {
            reset()
            return
        }

        vectorMaskLayer.path = path
        vectorMaskLayer.isHidden = false
        bitmapMaskLayer.contents = nil
        bitmapMaskLayer.isHidden = true
        renderingMode = .vector
    }

    private func applyBitmapMask(bounds: CGRect, scale: CGFloat, holes: [HoleRegion]) {
        guard let image = makeBitmapMask(bounds: bounds, scale: scale, holes: holes) else {
            reset()
            return
        }

        bitmapMaskLayer.contents = image
        bitmapMaskLayer.isHidden = false
        vectorMaskLayer.path = nil
        vectorMaskLayer.isHidden = true
        renderingMode = .bitmap
    }

    private func makeVectorMaskPath(bounds: CGRect, scale: CGFloat, holes: [HoleRegion]) -> CGPath? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let path = CGMutablePath()
        path.addRect(bounds)

        for hole in holes {
            let rect = alignRectToPixelGrid(hole.rect, scale: scale)
            guard rect.width > 0, rect.height > 0 else { continue }
            let radius = min(max(hole.cornerRadius, 0), min(rect.width, rect.height) / 2)
            if radius > 0 {
                path.addPath(
                    CGPath(
                        roundedRect: rect,
                        cornerWidth: radius,
                        cornerHeight: radius,
                        transform: nil
                    )
                )
            } else {
                path.addRect(rect)
            }
        }

        return path
    }

    private func makeBitmapMask(bounds: CGRect, scale: CGFloat, holes: [HoleRegion]) -> CGImage? {
        let pixelWidth = Int(ceil(bounds.width * scale))
        let pixelHeight = Int(ceil(bounds.height * scale))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.interpolationQuality = .none

        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))

        context.scaleBy(x: scale, y: scale)
        context.setBlendMode(.clear)

        for hole in holes {
            let rect = alignRectToPixelGrid(hole.rect, scale: scale)
            guard rect.width > 0, rect.height > 0 else { continue }
            let radius = min(max(hole.cornerRadius, 0), min(rect.width, rect.height) / 2)
            if radius > 0 {
                let path = CGPath(
                    roundedRect: rect,
                    cornerWidth: radius,
                    cornerHeight: radius,
                    transform: nil
                )
                context.addPath(path)
            } else {
                context.addRect(rect)
            }
            context.fillPath()
        }

        context.setBlendMode(.normal)
        return context.makeImage()
    }

    /// Snaps carve-out rects to the backing pixel grid so masks remain crisp on HiDPI displays.
    private func alignRectToPixelGrid(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard rect.width > 0, rect.height > 0, scale > 0 else { return rect }
        let scaledMinX = floor(rect.minX * scale)
        let scaledMinY = floor(rect.minY * scale)
        let scaledMaxX = ceil(rect.maxX * scale)
        let scaledMaxY = ceil(rect.maxY * scale)
        let width = max(0, scaledMaxX - scaledMinX)
        let height = max(0, scaledMaxY - scaledMinY)
        guard width > 0, height > 0 else { return .zero }
        return CGRect(
            x: scaledMinX / scale,
            y: scaledMinY / scale,
            width: width / scale,
            height: height / scale
        )
    }
}

/// Visual effect view that drives the blur material beneath the tinted overlay.
private final class OverlayBlurView: NSVisualEffectView {
    private var isBlurEnabled = true
    private var extraBlurRadius: CGFloat = 35
    private var colorTreatment: FocusOverlayColorTreatment = .preserveColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        blendingMode = .behindWindow  // Only this mode keeps background blur intact for full-screen overlays.
        material = .hudWindow  // Default material that provides a neutral blur across macOS themes.
        state = .active
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = false
        applyFilters()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        applyFilters()
    }

    /// Enables or disables the blur effect while keeping the view in place.
    func setBlurEnabled(_ isEnabled: Bool) {
        guard isBlurEnabled != isEnabled else { return }
        isBlurEnabled = isEnabled
        state = isEnabled ? .active : .inactive
        isHidden = !isEnabled
        if !isEnabled {
            layer?.mask = nil
            layer?.backgroundFilters = nil
        } else {
            applyFilters()
        }
    }

    /// Resets animation and masking state before the blur view is reused.
    override func prepareForReuse() {
        super.prepareForReuse()
        layer?.removeAllAnimations()
        layer?.mask = nil
        applyFilters()
    }

    /// Adjusts the gaussian blur radius used to soften captured content.
    func setExtraBlurRadius(_ radius: CGFloat) {
        let clamped = max(0, radius)
        guard abs(extraBlurRadius - clamped) >= .ulpOfOne else { return }
        extraBlurRadius = clamped
        applyFilters()
    }

    /// Updates the color treatment that should be applied beneath the tint overlay.
    func setColorTreatment(_ treatment: FocusOverlayColorTreatment) {
        guard colorTreatment != treatment else { return }
        colorTreatment = treatment
        applyFilters()
    }

    /// Applies an additional gaussian blur so the overall effect appears stronger.
    private func applyFilters() {
        guard isBlurEnabled, let layer else {
            self.layer?.backgroundFilters = nil
            return
        }

        var filters: [CIFilter] = []

        let radius = max(0, extraBlurRadius)
        if radius > 0, let blurFilter = CIFilter(name: "CIGaussianBlur") {
            blurFilter.setDefaults()
            blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
            filters.append(blurFilter)
        }

        if colorTreatment == .monochrome, let colorFilter = CIFilter(name: "CIColorControls") {
            colorFilter.setDefaults()
            colorFilter.setValue(0, forKey: kCIInputSaturationKey)
            filters.append(colorFilter)
        }

        layer.backgroundFilters = filters.isEmpty ? nil : filters
    }
}
