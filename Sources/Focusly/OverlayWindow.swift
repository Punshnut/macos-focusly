import AppKit
import QuartzCore

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
    private var areFiltersEnabled = true {
        didSet {
            blurEffectView.setBlurEnabled(areFiltersEnabled)
            tintOverlayView.isHidden = !areFiltersEnabled
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
        areFiltersEnabled = enabled
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

        guard areFiltersEnabled else {
            activeMaskRegions = []
            resetMaskLayers()
            return
        }

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
        guard areFiltersEnabled else {
            resetMaskLayers()
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
    private func resetMaskLayers() {
        tintOverlayView.layer?.mask = nil
        blurEffectView.layer?.mask = nil
        tintMaskingLayer.reset()
        blurMaskingLayer.reset()
        activeMaskRegions = []
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

/// Helper mask that rasterises carve-outs into a grayscale image (1 = visible, 0 = hidden).
private final class OverlayMaskLayer: CALayer {
    override init() {
        super.init()
        anchorPoint = .zero
        contentsGravity = .resize
    }

    override init(layer: Any) {
        super.init(layer: layer)
        anchorPoint = .zero
        contentsGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Rasterises static and dynamic carve-outs into a mask image and applies it to the layer.
    func configure(
        bounds: CGRect,
        scale: CGFloat,
        staticRects: [CGRect],
        dynamicRegions: [OverlayWindow.MaskRegion]
    ) {
        frame = bounds
        contentsScale = scale
        contents = makeMaskImage(
            bounds: bounds,
            scale: scale,
            staticRects: staticRects,
            dynamicRegions: dynamicRegions
        )
    }

    /// Releases the current mask image and collapses the layer.
    func reset() {
        contents = nil
        frame = .zero
    }

    /// Builds an alpha mask image where white pixels remain visible and transparent pixels punch holes.
    private func makeMaskImage(
        bounds: CGRect,
        scale: CGFloat,
        staticRects: [CGRect],
        dynamicRegions: [OverlayWindow.MaskRegion]
    ) -> CGImage? {
        let pixelWidth = Int((bounds.width * scale).rounded(.up))
        let pixelHeight = Int((bounds.height * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)

        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(bounds)

        staticRects.forEach { drawHole(in: $0, cornerRadius: 0, using: context) }
        dynamicRegions.forEach { drawHole(in: $0.rect, cornerRadius: $0.cornerRadius, using: context) }

        return context.makeImage()
    }

    /// Cuts a transparent hole either as a rounded rectangle or a hard rectangle inside the mask image.
    private func drawHole(in rect: CGRect, cornerRadius: CGFloat, using context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = min(max(cornerRadius, 0), min(rect.width, rect.height) / 2)
        context.setBlendMode(.clear)
        if radius > 0 {
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
            context.addPath(path)
            context.fillPath()
        } else {
            context.fill(rect)
        }
        context.setBlendMode(.normal)
    }
}

/// Visual effect view that drives the blur material beneath the tinted overlay.
private final class OverlayBlurView: NSVisualEffectView {
    private var isBlurEnabled = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        blendingMode = .behindWindow  // Only this mode keeps background blur intact for full-screen overlays.
        material = .hudWindow  // Default material that provides a neutral blur across macOS themes.
        state = .active
        wantsLayer = true
        layer?.masksToBounds = false
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Enables or disables the blur effect while keeping the view in place.
    func setBlurEnabled(_ isEnabled: Bool) {
        guard isBlurEnabled != isEnabled else { return }
        isBlurEnabled = isEnabled
        state = isEnabled ? .active : .inactive
        isHidden = !isEnabled
        if !isEnabled {
            layer?.mask = nil
        }
    }

    /// Resets animation and masking state before the blur view is reused.
    override func prepareForReuse() {
        super.prepareForReuse()
        layer?.removeAllAnimations()
        layer?.mask = nil
    }
}
