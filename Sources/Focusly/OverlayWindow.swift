import AppKit
import QuartzCore

@MainActor
final class OverlayWindow: NSPanel {
    private let blurView = OverlayBlurView()

    /// Describes a carved-out rect in the overlay.
    struct MaskRegion: Equatable {
        let rect: NSRect
        let cornerRadius: CGFloat
    }

    private let tintView: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        let layer = CALayer()
        layer.backgroundColor = NSColor.systemIndigo.withAlphaComponent(0.08).cgColor
        layer.isOpaque = false
        view.layer = layer
        return view
    }()

    private let tintMaskLayer = OverlayMaskLayer()
    private let blurMaskLayer = OverlayMaskLayer()
    private var currentStyle: FocusOverlayStyle?
    private var currentMaskRegions: [MaskRegion] = []
    private var staticExcludedRects: [NSRect] = []
    private(set) var displayID: DisplayID
    private weak var assignedScreen: NSScreen?
    private var filtersEnabled = true {
        didSet {
            blurView.setBlurEnabled(filtersEnabled)
            tintView.isHidden = !filtersEnabled
        }
    }

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
            setTintColor(.systemIndigo, alpha: clampedAlpha)
            return
        }
        tintView.layer?.backgroundColor = color.withAlphaComponent(clampedAlpha).cgColor
    }

    func setFiltersEnabled(_ enabled: Bool) {
        filtersEnabled = enabled
    }

    func setMaterial(_ material: NSVisualEffectView.Material) {
        blurView.material = material
    }

    func applyMask(excluding rectInContentView: NSRect?, cornerRadius: CGFloat = 0) {
        if let rect = rectInContentView {
            applyMask(regions: [MaskRegion(rect: rect, cornerRadius: cornerRadius)])
        } else {
            applyMask(regions: [])
        }
    }

    /// Allows the caller to carve out multiple regions at once (window, context menu, menus, ...).
    func applyMask(regions: [MaskRegion]) {
        guard let contentView else { return }

        guard filtersEnabled else {
            currentMaskRegions = []
            clearMasks()
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
            if currentMaskRegions.isEmpty {
                updateMaskLayer()
                return
            }
            currentMaskRegions = []
            updateMaskLayer()
            return
        }

        if currentMaskRegions.count == ordered.count {
            let matches = zip(currentMaskRegions, ordered).allSatisfy { current, updated in
                current.rect.isApproximatelyEqual(to: updated.rect, tolerance: tolerance) &&
                abs(current.cornerRadius - updated.cornerRadius) <= tolerance
            }
            if matches {
                return
            }
        }

        currentMaskRegions = ordered
        updateMaskLayer()
    }

    func updateToScreenFrame() {
        guard let targetScreen = assignedScreen ?? screen else { return }
        setFrame(targetScreen.frame, display: true)
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
    }

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

    private func configureContent() {
        guard let contentView else { return }
        contentView.translatesAutoresizingMaskIntoConstraints = true
        contentView.autoresizingMask = [.width, .height]

        contentView.addSubview(blurView)
        contentView.addSubview(tintView)

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: contentView.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
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
        alphaValue = 0
        tintView.layer?.removeAllAnimations()
        blurView.prepareForReuse()
        contentView?.layer?.removeAllAnimations()
    }

    func hide(animated: Bool) {
        let duration = currentStyle?.animationDuration ?? 0.25
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
        let targetOpacity = CGFloat(max(0, min(style.opacity, 1)))
        let targetColor = style.tint.makeColor()

        let applyValues = {
            if self.alphaValue != 1 {
                self.alphaValue = 1
            }
            self.blurView.alphaValue = targetOpacity
            self.tintView.alphaValue = targetOpacity
            self.tintView.layer?.backgroundColor = targetColor.cgColor
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
            self.blurView.animator().alphaValue = targetOpacity
            self.tintView.animator().alphaValue = targetOpacity
        }

        // Rebuild the mask layer graph using destinationOut sublayers so overlaps stay transparent.
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        tintView.layer?.backgroundColor = targetColor.cgColor
        CATransaction.commit()
    }

    func updateFrame(to screen: NSScreen) {
        setAssignedScreen(screen)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        if let targetScreen = assignedScreen ?? screen {
            recalculateStaticExclusions(for: targetScreen)
        } else {
            staticExcludedRects = []
        }
        updateMaskLayer()
    }

    private func recalculateStaticExclusions(for screen: NSScreen) {
        guard let contentView else {
            staticExcludedRects = []
            return
        }

        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)

        guard menuBarHeight > 0 else {
            staticExcludedRects = []
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
        staticExcludedRects = [rectInContent]
    }

    private func updateMaskLayer() {
        guard let contentView else { return }
        guard filtersEnabled else {
            clearMasks()
            return
        }

        let bounds = contentView.bounds
        let hasDynamicMask = !currentMaskRegions.isEmpty
        guard hasDynamicMask || !staticExcludedRects.isEmpty else {
            clearMasks()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let scale = backingScaleFactor
        tintMaskLayer.configure(
            bounds: bounds,
            scale: scale,
            staticRects: staticExcludedRects,
            dynamicRegions: currentMaskRegions
        )
        blurMaskLayer.configure(
            bounds: bounds,
            scale: scale,
            staticRects: staticExcludedRects,
            dynamicRegions: currentMaskRegions
        )

        if tintView.layer?.mask !== tintMaskLayer {
            tintView.layer?.mask = tintMaskLayer
        }
        if blurView.layer?.mask !== blurMaskLayer {
            blurView.layer?.mask = blurMaskLayer
        }

        CATransaction.commit()
    }

    private func clearMasks() {
        tintView.layer?.mask = nil
        blurView.layer?.mask = nil
        tintMaskLayer.reset()
        blurMaskLayer.reset()
        currentMaskRegions = []
    }

    private func shouldIgnoreMask(rect: NSRect, in bounds: NSRect) -> Bool {
        guard bounds.width > 0, bounds.height > 0 else { return true }
        let intersection = rect.intersection(bounds)
        guard !intersection.isNull else { return true }
        let coverage = (intersection.width * intersection.height) / (bounds.width * bounds.height)
        return coverage >= 0.98
    }

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

    func reset() {
        contents = nil
        frame = .zero
    }

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

private final class OverlayBlurView: NSVisualEffectView {
    private var blurEnabled = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        blendingMode = .behindWindow        //blur effect adjustment (macos), only .behindWindow works properly
        material = .hudWindow               //blur effect style (macos), be careful when changing. ".hudWindow" looks good in most cases
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

    func setBlurEnabled(_ enabled: Bool) {
        guard blurEnabled != enabled else { return }
        blurEnabled = enabled
        state = enabled ? .active : .inactive
        isHidden = !enabled
        if !enabled {
            layer?.mask = nil
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        layer?.removeAllAnimations()
        layer?.mask = nil
    }
}
