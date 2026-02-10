import AppKit
import QuartzCore
import CoreImage

/// Full-screen, click-through panel that renders Focusly's blur and tint overlay above a display.
@MainActor
final class OverlayWindow: NSPanel {
    private enum BlurBackend {
        case visualEffect(OverlayBlurView)
        case backdrop(BackdropHostView)

        @MainActor var view: NSView {
            switch self {
            case .visualEffect(let view): return view
            case .backdrop(let view): return view
            }
        }

        @MainActor var layer: CALayer? {
            switch self {
            case .visualEffect(let view): return view.layer
            case .backdrop(let view): return view.layer
            }
        }
    }

    private static var shouldUseBackdrop: Bool = {
        // CABackdropLayer can mis-render on some external displays; keep opt-in behind a user default.
        let enabled = UserDefaults.standard.bool(forKey: "Focusly.EnableBackdropBlur")
        return enabled && BackdropHostView.isSupported
    }()

    private let blurBackend: BlurBackend = {
        if OverlayWindow.shouldUseBackdrop {
            return .backdrop(BackdropHostView())
        }
        return .visualEffect(OverlayBlurView())
    }()

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
    private(set) var displayID: DisplayID
    private weak var boundScreen: NSScreen?
    private var isMenuBarExclusionEnabled = true
    /// Tracks whether blur/tint filters should currently be visible.
    private var areFiltersActive = true
    private var lastAppliedRefreshProfile: DisplayRefreshProfile?
    @available(macOS 12.0, *)
    private static let defaultFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 240, preferred: 120)
    // Keep a slight overlap with the menu bar backdrop to prevent a visible seam.
    private let menuBarFrameOverlapPoints: CGFloat = 1
    private enum AnimationTuning {
        static let minFade: TimeInterval = 0.04
        static let maxFade: TimeInterval = 0.1
        static let minMaskFade: TimeInterval = 0.02
        static let maxMaskFade: TimeInterval = 0.05

        static func clamp(_ duration: TimeInterval) -> TimeInterval {
            guard duration > 0 else { return 0 }
            return min(max(duration, minFade), maxFade)
        }

        static func maskFadeDuration(styleDuration: TimeInterval?, maskRegionCount: Int) -> TimeInterval {
            if maskRegionCount >= 6 {
                return 0
            }
            let styleDuration = clamp(styleDuration ?? 0.14)
            var resolved = min(max(styleDuration * 0.45, minMaskFade), maxMaskFade)
            if maskRegionCount >= 8 {
                resolved *= 0.78
            }
            return min(max(resolved, minMaskFade), maxMaskFade)
        }
    }
    private enum MaskComplexityLimits {
        static let interactiveRegionCap = resolvedRegionCap(
            key: "Focusly.MaskInteractiveRegionCap",
            defaultValue: 5,
            minValue: 3,
            maxValue: 10
        )
        static let steadyStateRegionCap = resolvedRegionCap(
            key: "Focusly.MaskSteadyRegionCap",
            defaultValue: 10,
            minValue: 5,
            maxValue: 20
        )

        private static func resolvedRegionCap(
            key: String,
            defaultValue: Int,
            minValue: Int,
            maxValue: Int
        ) -> Int {
            let configured = UserDefaults.standard.integer(forKey: key)
            if configured <= 0 {
                return defaultValue
            }
            return min(max(configured, minValue), maxValue)
        }
    }

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

    /// Enables or disables static menu bar exclusion from the main overlay mask.
    func setMenuBarExclusionEnabled(_ isEnabled: Bool) {
        guard isMenuBarExclusionEnabled != isEnabled else { return }
        isMenuBarExclusionEnabled = isEnabled
        updateToScreenFrame()
        refreshMaskLayers()
    }

    /// Toggles whether blur/tint effects should be active, optionally animating the transition.
    func setFiltersEnabled(_ enabled: Bool, animated: Bool = false) {
        guard areFiltersActive != enabled else { return }
        areFiltersActive = enabled

        let targetOpacity = CGFloat(max(0, min(currentStyle?.opacity ?? 1, 1)))
        let duration = animated ? AnimationTuning.clamp(currentStyle?.animationDuration ?? 0.22) : 0

        if enabled {
            switch blurBackend {
            case .visualEffect(let blurView):
                blurView.setBlurEnabled(true)
            case .backdrop(let host):
                host.setEnabled(true)
            }
            tintView.isHidden = false
            refreshMaskLayers()

            guard duration > 0 else {
                blurBackend.view.alphaValue = targetOpacity
                tintView.alphaValue = targetOpacity
                return
            }

            blurBackend.view.alphaValue = 0
            tintView.alphaValue = 0

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.blurBackend.view.animator().alphaValue = targetOpacity
                self.tintView.animator().alphaValue = targetOpacity
            }
        } else {
            let applyDisabledState = {
                switch self.blurBackend {
                case .visualEffect(let blurView):
                    blurView.setBlurEnabled(false)
                case .backdrop(let host):
                    host.setEnabled(false)
                }
                self.tintView.isHidden = true
                self.resetMaskLayers(preserveActiveRegions: true)
            }

            guard duration > 0 else {
                blurBackend.view.alphaValue = 0
                tintView.alphaValue = 0
                applyDisabledState()
                return
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.completionHandler = applyDisabledState
                self.blurBackend.view.animator().alphaValue = 0
                self.tintView.animator().alphaValue = 0
            }
        }
    }

    /// Updates the underlying `NSVisualEffectView` material used for blurring.
    func setMaterial(_ material: NSVisualEffectView.Material) {
        switch blurBackend {
        case .visualEffect(let blurView):
            blurView.material = material
        case .backdrop:
            break
        }
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
    func applyMask(regions: [MaskRegion], animated: Bool = false) {
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
        let isInteractiveUpdate = !animated
        let capped = cappedMaskRegions(
            from: ordered,
            in: bounds,
            isInteractiveUpdate: isInteractiveUpdate
        )

        guard !capped.isEmpty else {
            if currentMaskRegions.isEmpty {
                refreshMaskLayers()
                return
            }
            currentMaskRegions = []
            refreshMaskLayers(animated: animated)
            return
        }

        if currentMaskRegions.count == capped.count {
            let matches = zip(currentMaskRegions, capped).allSatisfy { current, updated in
                current.rect.isApproximatelyEqual(to: updated.rect, tolerance: tolerance) &&
                abs(current.cornerRadius - updated.cornerRadius) <= tolerance
            }
            if matches {
                return
            }
        }

        currentMaskRegions = capped
        refreshMaskLayers(animated: animated)
    }

    /// Enforces a hard cap on mask complexity, prioritizing the largest regions first.
    private func cappedMaskRegions(
        from regions: [MaskRegion],
        in bounds: NSRect,
        isInteractiveUpdate: Bool
    ) -> [MaskRegion] {
        guard !regions.isEmpty else { return regions }
        let limit = isInteractiveUpdate ? MaskComplexityLimits.interactiveRegionCap : MaskComplexityLimits.steadyStateRegionCap
        guard regions.count > limit else { return regions }

        let prioritized = regions.sorted { lhs, rhs in
            let lhsArea = lhs.rect.width * lhs.rect.height
            let rhsArea = rhs.rect.width * rhs.rect.height
            if lhsArea != rhsArea {
                return lhsArea > rhsArea
            }
            if lhs.rect.origin.y != rhs.rect.origin.y {
                return lhs.rect.origin.y < rhs.rect.origin.y
            }
            return lhs.rect.origin.x < rhs.rect.origin.x
        }

        let clamped = Array(prioritized.prefix(limit)).sorted { lhs, rhs in
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

        PerformanceDiagnostics.increment(
            isInteractiveUpdate ? "mask.region_cap.interactive_applied" : "mask.region_cap.steady_applied"
        )
        PerformanceDiagnostics.increment("mask.region_cap.trimmed_count", by: max(0, regions.count - clamped.count))
        return clamped
    }

    /// Resizes the window to match the bounds of the current target screen.
    func updateToScreenFrame() {
        guard let targetScreen = boundScreen ?? screen else { return }
        setFrame(resolvedFrame(for: targetScreen), display: true)
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

    /// Applies refresh rate hints tailored to the host display.
    func setRefreshProfile(_ profile: DisplayRefreshProfile?) {
        guard #available(macOS 12.0, *) else { return }
        guard lastAppliedRefreshProfile != profile else { return }
        lastAppliedRefreshProfile = profile
        let range = profile?.preferredFrameRateRange ?? Self.defaultFrameRateRange
        applyFrameRateRange(range)
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
        if #available(macOS 12.0, *) {
            applyFrameRateRange(Self.defaultFrameRateRange)
        }

        blurBackend.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(blurBackend.view)
        contentView.addSubview(tintView)

        NSLayoutConstraint.activate([
            blurBackend.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            blurBackend.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            blurBackend.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            blurBackend.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
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
        if case .visualEffect(let blurView) = blurBackend {
            blurView.prepareForReuse()
        }
        contentView?.layer?.removeAllAnimations()
        refreshMaskLayers()
    }

    /// Fades the window in when the overlay is presented on screen.
    func animatePresentation(duration: TimeInterval, animated: Bool) {
        PerformanceDiagnostics.increment("animation.overlay.present_scheduled")
        let clampedDuration = AnimationTuning.clamp(max(0, duration))
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
        PerformanceDiagnostics.increment("animation.overlay.hide_scheduled")
        let duration = AnimationTuning.clamp(currentStyle?.animationDuration ?? 0.22)
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
        PerformanceDiagnostics.increment("animation.overlay.style_apply")
        currentStyle = style
        let duration = AnimationTuning.clamp(style.animationDuration)
        let targetOpacity = CGFloat(max(0, min(style.opacity, 1)))
        let targetColor = style.tint.makeColor()

        let applyValues = {
            if self.alphaValue != 1 {
                self.alphaValue = 1
            }
            self.blurBackend.view.alphaValue = targetOpacity
            self.tintView.alphaValue = targetOpacity
            self.tintView.layer?.backgroundColor = targetColor.cgColor
        }

        switch blurBackend {
        case .visualEffect(let blurView):
            blurView.setMaterial(style.blurMaterial.visualEffectMaterial)
            blurView.setExtraBlurRadius(CGFloat(max(0, style.blurRadius)))
            blurView.setColorTreatment(style.colorTreatment)
        case .backdrop(let host):
            host.setBlurRadius(CGFloat(max(0, style.blurRadius)))
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
            self.blurBackend.view.animator().alphaValue = targetOpacity
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
        refreshMaskLayers()
    }

    /// Resolves the window frame depending on whether menu-bar exclusion is active.
    private func resolvedFrame(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        guard isMenuBarExclusionEnabled else {
            return screenFrame
        }

        let visibleFrame = screen.visibleFrame
        let menuBarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)
        guard menuBarHeight > 0 else {
            return screenFrame
        }

        let overlap = menuBarFrameOverlapPoints / max(screen.backingScaleFactor, 1)
        return NSRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: min(screenFrame.height, visibleFrame.height + overlap)
        )
    }

    /// Updates CALayer masks to reflect the latest static and dynamic carve-outs.
    private func refreshMaskLayers(animated: Bool = false) {
        let operationToken = PerformanceDiagnostics.begin()
        guard let contentView else {
            PerformanceDiagnostics.end(operationToken, operation: "layer.refresh_masks")
            return
        }
        guard areFiltersActive else {
            resetMaskLayers(preserveActiveRegions: true)
            PerformanceDiagnostics.end(operationToken, operation: "layer.refresh_masks")
            return
        }

        let bounds = contentView.bounds
        guard !currentMaskRegions.isEmpty else {
            resetMaskLayers()
            PerformanceDiagnostics.end(operationToken, operation: "layer.refresh_masks")
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let scale = backingScaleFactor
        tintMaskLayer.configure(
            bounds: bounds,
            scale: scale,
            staticRects: [],
            dynamicRegions: currentMaskRegions
        )
        blurMaskLayer.configure(
            bounds: bounds,
            scale: scale,
            staticRects: [],
            dynamicRegions: currentMaskRegions
        )

        if tintView.layer?.mask !== tintMaskLayer {
            tintView.layer?.mask = tintMaskLayer
        }
        if blurBackend.layer?.mask !== blurMaskLayer {
            blurBackend.layer?.mask = blurMaskLayer
        }

        CATransaction.commit()
        PerformanceDiagnostics.increment("layer.refresh_masks.region_count", by: currentMaskRegions.count)
        PerformanceDiagnostics.end(operationToken, operation: "layer.refresh_masks")

        guard animated else { return }
        let totalMaskRegionCount = currentMaskRegions.count
        let fadeDuration = AnimationTuning.maskFadeDuration(
            styleDuration: currentStyle?.animationDuration,
            maskRegionCount: totalMaskRegionCount
        )
        guard fadeDuration > 0 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        tintMaskLayer.add(fade, forKey: "maskFade")
        blurMaskLayer.add(fade, forKey: "maskFade")
    }

    /// Clears active masks and releases mask images.
    private func resetMaskLayers(preserveActiveRegions: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if tintView.layer?.mask === tintMaskLayer {
            tintView.layer?.mask = nil
        }
        if blurBackend.layer?.mask === blurMaskLayer {
            blurBackend.layer?.mask = nil
        }
        tintMaskLayer.reset()
        blurMaskLayer.reset()
        CATransaction.commit()
        if !preserveActiveRegions {
            currentMaskRegions = []
        }
    }

    /// Releases blur/mask state so the overlay can sit idle with negligible resource usage.
    private func prepareForDormancy() {
        setFiltersEnabled(false, animated: false)
        resetMaskLayers()
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

@available(macOS 12.0, *)
private extension OverlayWindow {
    func applyFrameRateRange(_ range: CAFrameRateRange) {
        contentView?.layer?.setValue(range, forKey: "preferredFrameRateRange")
        blurBackend.layer?.setValue(range, forKey: "preferredFrameRateRange")
        tintView.layer?.setValue(range, forKey: "preferredFrameRateRange")
    }
}

/// Mask layer that uses an even-odd vector path to keep updates GPU-friendly.
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
        vectorMaskLayer.isHidden = true
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
        let operationToken = PerformanceDiagnostics.begin()
        guard bounds.width > 0, bounds.height > 0 else {
            reset()
            PerformanceDiagnostics.end(operationToken, operation: "layer.mask_configure")
            return
        }

        let resolvedScale = max(scale, 1)
        frame = bounds
        contentsScale = resolvedScale
        vectorMaskLayer.frame = bounds
        vectorMaskLayer.contentsScale = resolvedScale

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
            PerformanceDiagnostics.end(operationToken, operation: "layer.mask_configure")
            return
        }

        applyVectorMask(bounds: bounds, scale: resolvedScale, holes: holeRegions)
        PerformanceDiagnostics.increment("layer.mask_configure.hole_count", by: holeRegions.count)
        PerformanceDiagnostics.end(operationToken, operation: "layer.mask_configure")
    }

    /// Releases active masks so the overlay can revert to a solid fill.
    func reset() {
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

    /// Uses a vector path to punch transparent holes when carve-outs do not overlap.
    private func applyVectorMask(bounds: CGRect, scale: CGFloat, holes: [HoleRegion]) {
        guard let path = makeVectorMaskPath(bounds: bounds, scale: scale, holes: holes) else {
            reset()
            return
        }

        vectorMaskLayer.path = path
        vectorMaskLayer.isHidden = false
        renderingMode = .vector
        Self.diagnosticsTracker.recordVectorFrame()
        PerformanceDiagnostics.increment("layer.mask_render.vector")
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
