import AppKit
import QuartzCore
import CoreImage

/// Full-screen, click-through panel that renders Focusly's blur and tint overlay above a display.
@MainActor
final class OverlayWindow: NSPanel {
    private let overlayBlurView = OverlayBlurView()

    /// Represents a transparent region that should be carved out of the overlay.
    struct MaskRegion: Equatable {
        let rect: NSRect
        let cornerRadius: CGFloat
    }

    /// Summarizes how often mask rendering falls back to CPU-bound bitmap mode.
    struct OverlayMaskRenderingDiagnostics {
        let vectorFrames: UInt64
        let bitmapFrames: UInt64

        var totalFrames: UInt64 { vectorFrames + bitmapFrames }
        var bitmapRatio: Double {
            guard totalFrames > 0 else { return 0 }
            return Double(bitmapFrames) / Double(totalFrames)
        }
    }

    /// Semi-transparent tint view that sits on top of the blur to colorize the overlay.
    private let tintView: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        let layer = CALayer()
        layer.backgroundColor = NSColor.systemIndigo.withAlphaComponent(0.08).cgColor
        layer.isOpaque = false
        layer.drawsAsynchronously = true
        layer.allowsGroupOpacity = true
        view.layer = layer
        return view
    }()

    private let tintMaskLayer = OverlayMaskLayer()
    private let blurMaskLayer = OverlayMaskLayer()
    private var currentStyle: FocusOverlayStyle?
    private var currentMaskRegions: [MaskRegion] = []
    private var staticTintExclusions: [NSRect] = []
    private var staticBlurExclusions: [NSRect] = []
    private(set) var displayID: DisplayID
    private weak var boundScreen: NSScreen?
    /// Tracks whether blur/tint filters should currently be visible.
    private var areFiltersActive = true

    /// Creates a new overlay window that is pinned to the given screen and display identifier.
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
        boundScreen = screen
        configureWindow()
        configureContent()
        updateToScreenFrame()
    }

    /// Exposes aggregate mask rendering stats so controllers can detect fallback hot-spots.
    @MainActor
    static func maskRenderingDiagnostics() -> OverlayMaskRenderingDiagnostics {
        OverlayMaskLayer.diagnosticsSnapshot()
    }

    /// Convenience initializer that derives the display identifier from the screen.
    convenience init(screen: NSScreen) {
        let resolvedDisplayID = OverlayWindow.resolveDisplayIdentifier(for: screen)
        self.init(screen: screen, displayID: resolvedDisplayID)
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
        tintView.layer?.backgroundColor = color.withAlphaComponent(clampedAlpha).cgColor
    }

    /// Adjusts the tint opacity while preserving the existing color.
    func setTintAlpha(_ alpha: CGFloat) {
        let clampedAlpha = max(0, min(alpha, 1))
        guard let color = tintView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) else {
            setTintColor(.systemIndigo, alpha: clampedAlpha)
            return
        }
        tintView.layer?.backgroundColor = color.withAlphaComponent(clampedAlpha).cgColor
    }

    /// Toggles whether blur/tint effects should be active, optionally animating the transition.
    func setFiltersEnabled(_ enabled: Bool, animated: Bool = false) {
        guard areFiltersActive != enabled else { return }
        areFiltersActive = enabled

        let targetOpacity = CGFloat(max(0, min(currentStyle?.opacity ?? 1, 1)))
        let duration = animated ? max(0, currentStyle?.animationDuration ?? 0.25) : 0

        if enabled {
            overlayBlurView.setBlurEnabled(true)
            tintView.isHidden = false
            refreshMaskLayers()

            guard duration > 0 else {
                overlayBlurView.alphaValue = targetOpacity
                tintView.alphaValue = targetOpacity
                return
            }

            overlayBlurView.alphaValue = 0
            tintView.alphaValue = 0

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.overlayBlurView.animator().alphaValue = targetOpacity
                self.tintView.animator().alphaValue = targetOpacity
            }
        } else {
            let applyDisabledState = {
                self.overlayBlurView.setBlurEnabled(false)
                self.tintView.isHidden = true
                self.resetMaskLayers(preserveActiveRegions: true)
            }

            guard duration > 0 else {
                overlayBlurView.alphaValue = 0
                tintView.alphaValue = 0
                applyDisabledState()
                return
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.completionHandler = applyDisabledState
                self.overlayBlurView.animator().alphaValue = 0
                self.tintView.animator().alphaValue = 0
            }
        }
    }

    /// Updates the underlying `NSVisualEffectView` material used for blurring.
    func setMaterial(_ material: NSVisualEffectView.Material) {
        overlayBlurView.material = material
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
            if currentMaskRegions.isEmpty {
                refreshMaskLayers()
                return
            }
            currentMaskRegions = []
            refreshMaskLayers()
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
        refreshMaskLayers()
    }

    /// Resizes the window to match the bounds of the current target screen.
    func updateToScreenFrame() {
        guard let targetScreen = boundScreen ?? screen else { return }
        setFrame(targetScreen.frame, display: true)
    }

    /// Changes the screen the overlay is attached to and resizes accordingly.
    func bind(to screen: NSScreen) {
        boundScreen = screen
        updateToScreenFrame()
    }

    /// Returns the cached CoreGraphics display identifier used to map back to a screen.
    func associatedDisplayID() -> DisplayID {
        displayID
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
        allowsConcurrentViewDrawing = true
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
        contentView.wantsLayer = true
        contentView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        contentView.layerContentsPlacement = .scaleAxesIndependently
        contentView.layer?.drawsAsynchronously = true
        contentView.layer?.allowsEdgeAntialiasing = true
        contentView.layer?.contentsFormat = .RGBA16Float

        contentView.addSubview(overlayBlurView)
        contentView.addSubview(tintView)

        NSLayoutConstraint.activate([
            overlayBlurView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            overlayBlurView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            overlayBlurView.topAnchor.constraint(equalTo: contentView.topAnchor),
            overlayBlurView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
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
        tintView.layer?.removeAllAnimations()
        overlayBlurView.prepareForReuse()
        contentView?.layer?.removeAllAnimations()
        if let targetScreen = boundScreen ?? screen {
            recalculateStaticExclusions(for: targetScreen)
        }
        refreshMaskLayers()
    }

    /// Fades the window in when the overlay is presented on screen.
    func animatePresentation(duration: TimeInterval, animated: Bool) {
        let clampedDuration = max(0, duration)
        guard animated, clampedDuration > 0 else {
            alphaValue = 1
            return
        }

        alphaValue = 0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = clampedDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 1
        }
    }

    /// Hides the overlay, optionally animating the fade-out.
    func hide(animated: Bool) {
        let duration = currentStyle?.animationDuration ?? 0.25
        let teardown = { [weak self] in
            guard let self else { return }
            self.alphaValue = 0
            self.orderOut(nil)
            self.prepareForDormancy()
        }

        guard animated, duration > 0 else {
            teardown()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.completionHandler = teardown
            self.animator().alphaValue = 0
        }
    }

    /// Applies the supplied overlay style, optionally animating opacity and colors.
    func apply(style: FocusOverlayStyle, animated: Bool) {
        currentStyle = style
        let duration = style.animationDuration
        let targetOpacity = CGFloat(max(0, min(style.opacity, 1)))
        let targetColor = style.tint.makeColor()

        let applyValues = {
            if self.alphaValue != 1 {
                self.alphaValue = 1
            }
            self.overlayBlurView.alphaValue = targetOpacity
            self.tintView.alphaValue = targetOpacity
            self.tintView.layer?.backgroundColor = targetColor.cgColor
        }

        overlayBlurView.setMaterial(style.blurMaterial.visualEffectMaterial)
        overlayBlurView.setExtraBlurRadius(CGFloat(max(0, style.blurRadius)))
        overlayBlurView.setColorTreatment(style.colorTreatment)

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
            self.overlayBlurView.animator().alphaValue = targetOpacity
            self.tintView.animator().alphaValue = targetOpacity
        }

        // Rebuild the mask layer graph using destinationOut sublayers so overlaps stay transparent.
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        tintView.layer?.backgroundColor = targetColor.cgColor
        CATransaction.commit()
    }

    /// Re-associates the overlay with a different screen while keeping geometry in sync.
    func updateFrame(to screen: NSScreen) {
        bind(to: screen)
    }

    /// Keeps static exclusions in sync whenever the window's frame changes.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        if let targetScreen = boundScreen ?? screen {
            recalculateStaticExclusions(for: targetScreen)
        } else {
            staticTintExclusions = []
            staticBlurExclusions = []
        }
        refreshMaskLayers()
    }

    /// Calculates static exclusions such as the menu bar so they stay transparent.
    private func recalculateStaticExclusions(for screen: NSScreen) {
        guard let contentView else {
            staticTintExclusions = []
            staticBlurExclusions = []
            return
        }

        guard let menuBarRectInScreen = MenuBarBackdropWindow.menuBarFrame(for: screen) else {
            staticTintExclusions = []
            staticBlurExclusions = []
            return
        }

        let menuBarRectInWindow = convertFromScreen(menuBarRectInScreen)
        let rectInContent = contentView.convert(menuBarRectInWindow, from: nil)

        let backingRect = contentView.convertToBacking(rectInContent).integral
        let alignedRect = contentView.convertFromBacking(backingRect)

        staticTintExclusions = [alignedRect]
        staticBlurExclusions = [alignedRect]
    }

    /// Updates CALayer masks to reflect the latest static and dynamic carve-outs.
    private func refreshMaskLayers() {
        guard let contentView else { return }
        guard areFiltersActive else {
            resetMaskLayers(preserveActiveRegions: true)
            return
        }

        let bounds = contentView.bounds
        let hasDynamicMask = !currentMaskRegions.isEmpty
        let hasStaticMask = !staticTintExclusions.isEmpty || !staticBlurExclusions.isEmpty
        guard hasDynamicMask || hasStaticMask else {
            resetMaskLayers()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let scale = backingScaleFactor
        tintMaskLayer.configure(
            bounds: bounds,
            scale: scale,
            staticRects: staticTintExclusions,
            dynamicRegions: currentMaskRegions
        )
        blurMaskLayer.configure(
            bounds: bounds,
            scale: scale,
            staticRects: staticBlurExclusions,
            dynamicRegions: currentMaskRegions
        )

        if tintView.layer?.mask !== tintMaskLayer {
            tintView.layer?.mask = tintMaskLayer
        }
        if overlayBlurView.layer?.mask !== blurMaskLayer {
            overlayBlurView.layer?.mask = blurMaskLayer
        }

        CATransaction.commit()
    }

    /// Clears active masks and releases mask images.
    private func resetMaskLayers(preserveActiveRegions: Bool = false) {
        tintView.layer?.mask = nil
        overlayBlurView.layer?.mask = nil
        tintMaskLayer.reset()
        blurMaskLayer.reset()
        if !preserveActiveRegions {
            currentMaskRegions = []
        }
    }

    /// Releases blur/mask state so the overlay can sit idle with negligible resource usage.
    private func prepareForDormancy() {
        setFiltersEnabled(false, animated: false)
        resetMaskLayers()
        staticTintExclusions = []
        staticBlurExclusions = []
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

    private final class DiagnosticsTracker: @unchecked Sendable {
        private var vectorFrames: UInt64 = 0
        private var bitmapFrames: UInt64 = 0

        func recordVectorFrame() {
            vectorFrames &+= 1
        }

        func recordBitmapFrame() {
            bitmapFrames &+= 1
        }

        func snapshot() -> OverlayWindow.OverlayMaskRenderingDiagnostics {
            OverlayWindow.OverlayMaskRenderingDiagnostics(
                vectorFrames: vectorFrames,
                bitmapFrames: bitmapFrames
            )
        }
    }

    private struct HoleRegion {
        var rect: CGRect
        var cornerRadius: CGFloat
        var alignToPixelGrid: Bool
    }

    private let vectorMaskLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.anchorPoint = .zero
        layer.fillRule = .evenOdd
        layer.fillColor = NSColor.white.cgColor
        layer.drawsAsynchronously = true
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
        layer.drawsAsynchronously = true
        layer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        layer.contentsGravity = .resize
        return layer
    }()

    private var renderingMode: RenderingMode = .none
    private static let diagnosticsTracker = DiagnosticsTracker()

    override init() {
        super.init()
        drawsAsynchronously = true
        configureLayerHierarchy()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        configureLayerHierarchy()
    }

    /// Sets up the vector and bitmap mask layers used to carve holes in the overlay.
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
                HoleRegion(rect: rect, cornerRadius: 0, alignToPixelGrid: false),
                to: &holeRegions,
                tolerance: tolerance
            )
        }

        for region in dynamicRegions {
            let rect = region.rect
            guard rect.width > 0, rect.height > 0 else { continue }
            let radius = min(max(region.cornerRadius, 0), min(rect.width, rect.height) / 2)
            appendHole(
                HoleRegion(rect: rect, cornerRadius: radius, alignToPixelGrid: true),
                to: &holeRegions,
                tolerance: tolerance
            )
        }

        guard !holeRegions.isEmpty else {
            reset()
            return
        }

        if holesOverlap(holeRegions, tolerance: tolerance, scale: resolvedScale) {
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

    /// Merges a candidate carve-out with existing holes, de-duplicating overlapping regions.
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
            holes[index].alignToPixelGrid = holes[index].alignToPixelGrid && candidate.alignToPixelGrid
        } else {
            holes.append(candidate)
        }
    }

    /// Determines whether any existing holes intersect enough to warrant bitmap masking.
    private func holesOverlap(_ holes: [HoleRegion], tolerance: CGFloat, scale: CGFloat) -> Bool {
        guard holes.count > 1 else { return false }
        let pixelScale = max(scale, 1)
        let minPixelOverlap: CGFloat = 96
        let minimumArea = max(minPixelOverlap / (pixelScale * pixelScale), tolerance * tolerance * 6)
        for index in 0..<(holes.count - 1) {
            let first = holes[index].rect
            for comparisonIndex in (index + 1)..<holes.count {
                let second = holes[comparisonIndex].rect
                let intersection = first.intersection(second)
                guard !intersection.isNull else { continue }
                let overlapArea = intersection.width * intersection.height
                guard overlapArea > minimumArea else { continue }
                let firstArea = max(first.width * first.height, .ulpOfOne)
                let secondArea = max(second.width * second.height, .ulpOfOne)
                let overlapRatio = overlapArea / min(firstArea, secondArea)
                if overlapRatio >= 0.5 {
                    return true
                }
            }
        }
        return false
    }

    /// Uses a vector path to punch transparent holes when carve-outs do not overlap.
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
        Self.diagnosticsTracker.recordVectorFrame()
    }

    /// Falls back to a bitmap mask when regions intersect and vector subtraction would bleed.
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
        Self.diagnosticsTracker.recordBitmapFrame()
    }

    /// Builds the even-odd vector path representing all static and dynamic carve-outs.
    private func makeVectorMaskPath(bounds: CGRect, scale: CGFloat, holes: [HoleRegion]) -> CGPath? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let path = CGMutablePath()
        path.addRect(bounds)

        for hole in holes {
            let rect = alignRectToPixelGrid(hole.rect, scale: scale, align: hole.alignToPixelGrid)
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

    /// Rasterizes a mask image with transparent cutouts for each carve-out region.
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
            let rect = alignRectToPixelGrid(hole.rect, scale: scale, align: hole.alignToPixelGrid)
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
    private func alignRectToPixelGrid(_ rect: CGRect, scale: CGFloat, align: Bool) -> CGRect {
        guard align else { return rect }
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

    /// Shares the accumulated diagnostics so callers can monitor fallback usage.
    static func diagnosticsSnapshot() -> OverlayWindow.OverlayMaskRenderingDiagnostics {
        diagnosticsTracker.snapshot()
    }
}

/// Visual effect view that drives the blur material beneath the tinted overlay.
final class OverlayBlurView: NSVisualEffectView {
    private var isBlurEnabled = true
    private var extraBlurRadius: CGFloat = 35
    private var colorTreatment: FocusOverlayColorTreatment = .preserveColor
    private var appliedMaterial: NSVisualEffectView.Material = .hudWindow

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        blendingMode = .behindWindow  // Only this mode keeps background blur intact for full-screen overlays.
        material = .hudWindow  // Default material that provides a neutral blur across macOS themes.
        appliedMaterial = .hudWindow
        state = .active
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.masksToBounds = false
        layer?.drawsAsynchronously = true
        applyFilters()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Keeps Core Image filter configuration synchronized with geometry updates.
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
            material = appliedMaterial
            applyFilters()
        }
    }

    /// Resets animation and masking state before the blur view is reused.
    override func prepareForReuse() {
        super.prepareForReuse()
        layer?.removeAllAnimations()
        layer?.mask = nil
        material = appliedMaterial
        applyFilters()
    }

    /// Updates the visual effect material backing the overlay blur.
    func setMaterial(_ material: NSVisualEffectView.Material) {
        guard appliedMaterial != material else { return }
        appliedMaterial = material
        self.material = material
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

        filters.append(contentsOf: colorTreatmentFilters(for: colorTreatment))

        layer.backgroundFilters = filters.isEmpty ? nil : filters
    }

    /// Builds the Core Image filter chain that corresponds to the requested treatment.
    private func colorTreatmentFilters(for treatment: FocusOverlayColorTreatment) -> [CIFilter] {
        switch treatment {
        case .preserveColor:
            return []
        case .dark:
            guard
                let colorControls = CIFilter(name: "CIColorControls"),
                let exposure = CIFilter(name: "CIExposureAdjust")
            else { return [] }
            colorControls.setDefaults()
            colorControls.setValue(0.18, forKey: kCIInputSaturationKey)
            colorControls.setValue(-0.42, forKey: kCIInputBrightnessKey)
            colorControls.setValue(1.18, forKey: kCIInputContrastKey)
            exposure.setDefaults()
            exposure.setValue(-0.45, forKey: kCIInputEVKey)
            return [colorControls, exposure]
        case .whiteOverlay:
            guard
                let colorControls = CIFilter(name: "CIColorControls"),
                let gamma = CIFilter(name: "CIGammaAdjust"),
                let exposure = CIFilter(name: "CIExposureAdjust")
            else { return [] }
            colorControls.setDefaults()
            colorControls.setValue(0.22, forKey: kCIInputSaturationKey)
            colorControls.setValue(0.52, forKey: kCIInputBrightnessKey)
            colorControls.setValue(0.95, forKey: kCIInputContrastKey)
            gamma.setDefaults()
            gamma.setValue(0.78, forKey: "inputPower")
            exposure.setDefaults()
            exposure.setValue(0.55, forKey: kCIInputEVKey)
            return [colorControls, gamma, exposure]
        }
    }
}
