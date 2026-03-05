import AppKit
import QuartzCore
import CoreImage
import os.log

/// Full-screen, click-through panel that renders Focusly's blur and tint overlay above a display.
@MainActor
final class OverlayWindow: NSPanel {
    enum EffectQualityMode {
        case full
        case safeDimOnly
    }

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
        enum TitlebarStyle: Int, Sendable {
            case unknown
            case unified
            case separated
        }

        let rect: NSRect
        let cornerRadius: CGFloat
        let windowID: Int?
        let titlebarStyle: TitlebarStyle
        let ownerPID: pid_t?

        init(
            rect: NSRect,
            cornerRadius: CGFloat,
            windowID: Int? = nil,
            titlebarStyle: TitlebarStyle = .unknown,
            ownerPID: pid_t? = nil
        ) {
            self.rect = rect
            self.cornerRadius = cornerRadius
            self.windowID = windowID
            self.titlebarStyle = titlebarStyle
            self.ownerPID = ownerPID
        }
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
    private let maskPipelineLogger = Logger(subsystem: "com.focusly.app", category: "OverlayMaskPipeline")
    private let geometryLogger = Logger(subsystem: "com.focusly.app", category: "OverlayGeometry")
    private var currentStyle: FocusOverlayStyle?
    private var currentMaskRegions: [MaskRegion] = []
    private var previousMaskBounds: CGRect = .zero
    private var previousMaskScale: CGFloat = 0
    private var fullMaskRebuildCount: UInt64 = 0
    private var incrementalMaskUpdateCount: UInt64 = 0
    private var translationOnlyMaskUpdateCount: UInt64 = 0
    private var nextMaskPipelineLogDate: Date = .distantPast
    private var effectQualityMode: EffectQualityMode = .full
    private var isEmergencyHidden = false
    private(set) var displayID: DisplayID
    private weak var boundScreen: NSScreen?
    private var isMenuBarExclusionEnabled = true
    /// Tracks whether blur/tint filters should currently be visible.
    private var areFiltersActive = true
    private var pendingMaskTranslationDelta: CGVector?
    private var lastAppliedRefreshProfile: DisplayRefreshProfile?
    @available(macOS 12.0, *)
    private static let defaultFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 240, preferred: 120)
    private static let showsMenuBarDebugOverlay: Bool = {
        UserDefaults.standard.bool(forKey: "Focusly.DebugMenuBarGeometryOverlay")
    }()
    private let debugScreenFrameLayer = CAShapeLayer()
    private let debugVisibleFrameLayer = CAShapeLayer()
    private let debugMaskRegionLayer = CAShapeLayer()
    private enum AnimationTuning {
        static let minFade: TimeInterval = 0.08
        static let maxFade: TimeInterval = 0.14
        static let minMaskFade: TimeInterval = 0.08
        static let maxMaskFade: TimeInterval = 0.14

        /// Clamps fade duration to a bounded range tuned for overlay responsiveness.
        static func clamp(_ duration: TimeInterval) -> TimeInterval {
            guard duration > 0 else { return 0 }
            return min(max(duration, minFade), maxFade)
        }

        /// Computes mask fade duration based on style duration and mask region complexity.
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

        /// Reads a region cap from defaults and constrains it to safe min/max bounds.
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
    /// Returns aggregate render-mode diagnostics from the shared mask layer tracker.
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
        cancelActiveOverlayAnimations()

        let targetOpacity = CGFloat(max(0, min(currentStyle?.opacity ?? 1, 1)))
        let duration = animated ? AnimationTuning.clamp(currentStyle?.animationDuration ?? 0.22) : 0

        if enabled {
            applyEffectQualityMode(targetOpacity: targetOpacity)
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
            return MaskRegion(
                rect: clipped,
                cornerRadius: limitedRadius,
                windowID: region.windowID,
                titlebarStyle: region.titlebarStyle,
                ownerPID: region.ownerPID
            )
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

        let priorRegions = currentMaskRegions
        pendingMaskTranslationDelta = translationDelta(from: priorRegions, to: capped, tolerance: tolerance)
        currentMaskRegions = capped
        refreshMaskLayers(animated: animated)
    }

    /// Detects drag-only updates where all mask holes moved by the same delta without shape changes.
    private func translationDelta(from previous: [MaskRegion], to next: [MaskRegion], tolerance: CGFloat) -> CGVector? {
        guard !previous.isEmpty, previous.count == next.count else { return nil }
        var resolvedDelta: CGVector?
        for (left, right) in zip(previous, next) {
            guard left.windowID == right.windowID else { return nil }
            guard left.ownerPID == right.ownerPID else { return nil }
            guard left.titlebarStyle == right.titlebarStyle else { return nil }
            guard abs(left.rect.width - right.rect.width) <= tolerance else { return nil }
            guard abs(left.rect.height - right.rect.height) <= tolerance else { return nil }
            guard abs(left.cornerRadius - right.cornerRadius) <= tolerance else { return nil }
            let dx = right.rect.origin.x - left.rect.origin.x
            let dy = right.rect.origin.y - left.rect.origin.y
            if let existing = resolvedDelta {
                guard abs(existing.dx - dx) <= tolerance, abs(existing.dy - dy) <= tolerance else { return nil }
            } else {
                resolvedDelta = CGVector(dx: dx, dy: dy)
            }
        }
        guard let resolvedDelta else { return nil }
        guard abs(resolvedDelta.dx) > tolerance || abs(resolvedDelta.dy) > tolerance else { return nil }
        return resolvedDelta
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
        let targetFrame = resolvedFrame(for: targetScreen)
        setFrame(targetFrame, display: true)
        logResolvedGeometry(screen: targetScreen, targetFrame: targetFrame)
        refreshDebugGeometryOverlay()
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
        // macOS does not expose a stable global level "below active app window but above all other windows".
        // Best practical approximation is a high non-activating overlay plus precise active-window punch-outs.
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        becomesKeyOnlyIfNeeded = false
        allowsConcurrentViewDrawing = true
        ignoresMouseEvents = true
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
            .fullScreenDisallowsTiling
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

        configureDebugGeometryOverlayIfNeeded()
    }

    /// Sets up optional debug geometry layers for screen/visible/mask visualization.
    private func configureDebugGeometryOverlayIfNeeded() {
        guard Self.showsMenuBarDebugOverlay, let rootLayer = contentView?.layer else { return }
        let layers: [(CAShapeLayer, NSColor)] = [
            (debugScreenFrameLayer, .systemRed),
            (debugVisibleFrameLayer, .systemYellow),
            (debugMaskRegionLayer, .systemGreen)
        ]
        for (layer, color) in layers {
            layer.fillColor = NSColor.clear.cgColor
            layer.strokeColor = color.cgColor
            layer.lineWidth = 1
            layer.zPosition = 10_000
            layer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
            if layer.superlayer == nil {
                rootLayer.addSublayer(layer)
            }
        }
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
        cancelActiveOverlayAnimations()
        let duration = AnimationTuning.clamp(style.animationDuration)
        let targetOpacity = CGFloat(max(0, min(style.opacity, 1)))
        let targetColor = style.tint.makeColor()

        let applyValues = {
            if self.alphaValue != 1 {
                self.alphaValue = 1
            }
            self.applyEffectQualityMode(targetOpacity: targetOpacity)
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
        Self.resolvedMainOverlayFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            menuBarExcluded: isMenuBarExclusionEnabled,
            backingScale: screen.backingScaleFactor
        )
    }

    /// Explicit menu-bar policy:
    /// - excluded: keep full-screen coverage except for the top menu-bar band
    /// - included: target full frame
    static func resolvedMainOverlayFrame(
        screenFrame: NSRect,
        visibleFrame: NSRect,
        menuBarExcluded: Bool,
        backingScale: CGFloat
    ) -> NSRect {
        guard menuBarExcluded else {
            let scale = max(backingScale, 1)
            return OverlayCoordinateConverter.alignRectToBackingGrid(screenFrame, scale: scale)
        }
        let menuBarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)
        guard menuBarHeight > 0 else {
            let scale = max(backingScale, 1)
            return OverlayCoordinateConverter.alignRectToBackingGrid(screenFrame, scale: scale)
        }
        let scale = max(backingScale, 1)
        // Keep a slight overlap with the menu-bar backdrop to avoid a seam.
        let overlap = 1.0 / scale
        let resolved = NSRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: min(screenFrame.height, max(0, screenFrame.height - menuBarHeight + overlap))
        )
        return OverlayCoordinateConverter.alignRectToBackingGrid(resolved, scale: scale)
    }

    /// Logs resolved overlay geometry for screen-policy diagnostics.
    private func logResolvedGeometry(screen: NSScreen, targetFrame: NSRect) {
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let menuBarHeight = max(0, screenFrame.maxY - visibleFrame.maxY)
        geometryLogger.debug(
            "overlay_frame_policy display=\(self.displayID, privacy: .public) menuBarExcluded=\(self.isMenuBarExclusionEnabled, privacy: .public) menuBarHeight=\(menuBarHeight, format: .fixed(precision: 2), privacy: .public) screenOrigin=(\(screenFrame.minX, format: .fixed(precision: 2), privacy: .public),\(screenFrame.minY, format: .fixed(precision: 2), privacy: .public)) visibleOrigin=(\(visibleFrame.minX, format: .fixed(precision: 2), privacy: .public),\(visibleFrame.minY, format: .fixed(precision: 2), privacy: .public)) overlayOrigin=(\(targetFrame.minX, format: .fixed(precision: 2), privacy: .public),\(targetFrame.minY, format: .fixed(precision: 2), privacy: .public))"
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

        cancelActiveOverlayAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let scale = backingScaleFactor
        let requiresFullRebuild =
            !previousMaskBounds.equalTo(bounds) ||
            abs(previousMaskScale - scale) > 0.001
        let canUseTranslationFastPath = !requiresFullRebuild &&
            tintView.layer?.mask === tintMaskLayer &&
            blurBackend.layer?.mask === blurMaskLayer &&
            pendingMaskTranslationDelta != nil
        if canUseTranslationFastPath, let translation = pendingMaskTranslationDelta {
            if tintMaskLayer.applyTranslation(translation, scale: scale),
               blurMaskLayer.applyTranslation(translation, scale: scale) {
                translationOnlyMaskUpdateCount &+= 1
                pendingMaskTranslationDelta = nil
                CATransaction.commit()
                maybeLogMaskPipelineRefreshStats()
                PerformanceDiagnostics.increment("layer.refresh_masks.translation_only")
                PerformanceDiagnostics.increment("layer.refresh_masks.region_count", by: currentMaskRegions.count)
                refreshDebugGeometryOverlay()
                PerformanceDiagnostics.end(operationToken, operation: "layer.refresh_masks")
                return
            }
        }
        pendingMaskTranslationDelta = nil
        if requiresFullRebuild {
            fullMaskRebuildCount &+= 1
        } else {
            incrementalMaskUpdateCount &+= 1
        }
        previousMaskBounds = bounds
        previousMaskScale = scale
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
        maybeLogMaskPipelineRefreshStats()
        PerformanceDiagnostics.increment("layer.refresh_masks.region_count", by: currentMaskRegions.count)
        refreshDebugGeometryOverlay()
        PerformanceDiagnostics.end(operationToken, operation: "layer.refresh_masks")

        guard animated else { return }
        cancelActiveOverlayAnimations()
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
        previousMaskBounds = .zero
        previousMaskScale = 0
        if !preserveActiveRegions {
            currentMaskRegions = []
        }
        pendingMaskTranslationDelta = nil
        refreshDebugGeometryOverlay()
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

    /// Emits periodic refresh stats for mask rebuild strategy diagnostics.
    private func maybeLogMaskPipelineRefreshStats(referenceDate: Date = Date()) {
        if nextMaskPipelineLogDate == .distantPast {
            nextMaskPipelineLogDate = referenceDate.addingTimeInterval(4)
            return
        }
        guard referenceDate >= nextMaskPipelineLogDate else { return }
        maskPipelineLogger.log(
            "overlay_mask_refresh fullRebuilds=\(self.fullMaskRebuildCount, privacy: .public) incrementalPathUpdates=\(self.incrementalMaskUpdateCount, privacy: .public) translationOnlyUpdates=\(self.translationOnlyMaskUpdateCount, privacy: .public)"
        )
        nextMaskPipelineLogDate = referenceDate.addingTimeInterval(4)
    }

    /// Rebuilds debug overlay paths for screen, visible frame, and active mask regions.
    private func refreshDebugGeometryOverlay() {
        guard Self.showsMenuBarDebugOverlay else { return }
        guard let contentView, let targetScreen = boundScreen ?? screen else { return }

        let overlayFrame = frame
        let contentBounds = contentView.bounds
        let scale = max(backingScaleFactor, 1)

        let screenRect = OverlayCoordinateConverter.globalRectToOverlayContent(
            targetScreen.frame,
            overlayFrame: overlayFrame,
            contentBounds: contentBounds,
            backingScale: scale
        ) ?? .zero
        let visibleRect = OverlayCoordinateConverter.globalRectToOverlayContent(
            targetScreen.visibleFrame,
            overlayFrame: overlayFrame,
            contentBounds: contentBounds,
            backingScale: scale
        ) ?? .zero

        debugScreenFrameLayer.frame = contentBounds
        debugVisibleFrameLayer.frame = contentBounds
        debugMaskRegionLayer.frame = contentBounds
        debugScreenFrameLayer.path = CGPath(rect: screenRect, transform: nil)
        debugVisibleFrameLayer.path = CGPath(rect: visibleRect, transform: nil)

        let combinedMasks = CGMutablePath()
        for region in currentMaskRegions {
            combinedMasks.addRect(region.rect)
        }
        debugMaskRegionLayer.path = combinedMasks
    }

    /// Switches effect quality mode and reapplies current target opacity.
    func setEffectQualityMode(_ mode: EffectQualityMode) {
        guard effectQualityMode != mode else { return }
        effectQualityMode = mode
        let targetOpacity = CGFloat(max(0, min(currentStyle?.opacity ?? 1, 1)))
        applyEffectQualityMode(targetOpacity: targetOpacity)
    }

    /// Temporarily hides the overlay when emergency fallback is engaged.
    func setEmergencyHidden(_ hidden: Bool) {
        guard isEmergencyHidden != hidden else { return }
        isEmergencyHidden = hidden
        if hidden {
            orderOut(nil)
            return
        }
        orderFrontRegardless()
        refreshMaskLayers()
    }

    /// Applies blur/tint visibility rules for the active effect quality mode.
    private func applyEffectQualityMode(targetOpacity: CGFloat) {
        switch effectQualityMode {
        case .full:
            switch blurBackend {
            case .visualEffect(let blurView):
                blurView.setBlurEnabled(true)
            case .backdrop(let host):
                host.setEnabled(true)
            }
            blurBackend.view.isHidden = false
            blurBackend.view.alphaValue = targetOpacity
            tintView.alphaValue = targetOpacity
            tintView.isHidden = false
        case .safeDimOnly:
            switch blurBackend {
            case .visualEffect(let blurView):
                blurView.setBlurEnabled(false)
            case .backdrop(let host):
                host.setEnabled(false)
            }
            blurBackend.view.alphaValue = 0
            blurBackend.view.isHidden = true
            tintView.alphaValue = min(targetOpacity, 0.42)
            tintView.isHidden = false
        }
    }

    /// Stops all in-flight layer/view animations before switching fallback or visibility states.
    private func cancelActiveOverlayAnimations() {
        animatiorReset(view: blurBackend.view)
        animatiorReset(view: tintView)
        tintView.layer?.removeAllAnimations()
        blurBackend.layer?.removeAllAnimations()
        tintMaskLayer.removeAllAnimations()
        blurMaskLayer.removeAllAnimations()
        contentView?.layer?.removeAllAnimations()
    }

    /// Synchronizes the animator proxy with the model value to avoid stale implicit animations.
    private func animatiorReset(view: NSView) {
        view.animator().alphaValue = view.alphaValue
    }
}

@available(macOS 12.0, *)
private extension OverlayWindow {
    /// Applies the preferred frame-rate hint to all composited overlay layers.
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

        /// Records one frame rendered via vector masking.
        func recordVectorFrame() {
            vectorFrames &+= 1
        }

        /// Records one frame rendered via bitmap fallback masking.
        func recordBitmapFrame() {
            bitmapFrames &+= 1
        }

        /// Returns the current render-mode counters for diagnostics consumers.
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
        var windowID: Int?
        var titlebarStyle: OverlayWindow.MaskRegion.TitlebarStyle
        var ownerPID: pid_t?
    }

    private struct WindowShapeCacheKey: Hashable {
        let windowID: Int
        let frameSignature: Int
        let cornerRadiusSignature: Int
        let titlebarStyle: Int
        let scaleSignature: Int
    }

    private struct WindowShapeCacheEntry {
        let path: CGPath
        let timestamp: Date
    }

    private struct MaskPipelineStats {
        var rebuildCount: UInt64 = 0
        var fastPathCount: UInt64 = 0
        var slowPathCount: UInt64 = 0
        var shapeCacheHits: UInt64 = 0
        var shapeCacheMisses: UInt64 = 0
        var totalRebuildTime: TimeInterval = 0
        var nextLogDate: Date = .distantPast
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
    private let logger = Logger(subsystem: "com.focusly.app", category: "OverlayMaskLayer")
    private var windowShapeCache: [WindowShapeCacheKey: WindowShapeCacheEntry] = [:]
    private let windowShapeCacheLifetime: TimeInterval = 12
    private let maximumWindowShapeCacheEntries = 320
    private var lastGeometryFingerprint: Int?
    private var accumulatedTranslation: CGVector = .zero
    private var translationBaseBounds: CGRect = .zero
    private var translationBaseScale: CGFloat = 1
    private var translationBaseHoles: [HoleRegion] = []
    private var stats = MaskPipelineStats()

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
        let rebuildStarted = Date()
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
        if accumulatedTranslation.dx != 0 || accumulatedTranslation.dy != 0 {
            accumulatedTranslation = .zero
            vectorMaskLayer.setAffineTransform(.identity)
        }

        let tolerance = max(1.0 / resolvedScale, 0.1)
        var holeRegions: [HoleRegion] = []
        holeRegions.reserveCapacity(staticRects.count + dynamicRegions.count)

        for rect in staticRects where rect.width > 0 && rect.height > 0 {
            appendHole(
                HoleRegion(
                    rect: rect,
                    cornerRadius: 0,
                    alignToPixelGrid: false,
                    windowID: nil,
                    titlebarStyle: .unknown,
                    ownerPID: nil
                ),
                to: &holeRegions,
                tolerance: tolerance
            )
        }

        for region in dynamicRegions {
            let rect = region.rect
            guard rect.width > 0, rect.height > 0 else { continue }
            let radius = min(max(region.cornerRadius, 0), min(rect.width, rect.height) / 2)
            appendHole(
                HoleRegion(
                    rect: rect,
                    cornerRadius: radius,
                    alignToPixelGrid: true,
                    windowID: region.windowID,
                    titlebarStyle: region.titlebarStyle,
                    ownerPID: region.ownerPID
                ),
                to: &holeRegions,
                tolerance: tolerance
            )
        }

        guard !holeRegions.isEmpty else {
            reset()
            PerformanceDiagnostics.end(operationToken, operation: "layer.mask_configure")
            return
        }

        let geometryFingerprint = geometryFingerprint(bounds: bounds, scale: resolvedScale, holes: holeRegions)
        if let last = lastGeometryFingerprint, last == geometryFingerprint {
            PerformanceDiagnostics.recordCache(key: "mask_pipeline_geometry", hit: true)
            stats.fastPathCount &+= 1
            stats.rebuildCount &+= 1
            stats.totalRebuildTime += Date().timeIntervalSince(rebuildStarted)
            maybeLogPipelineStats()
            PerformanceDiagnostics.end(operationToken, operation: "layer.mask_configure")
            return
        }
        PerformanceDiagnostics.recordCache(key: "mask_pipeline_geometry", hit: false)
        lastGeometryFingerprint = geometryFingerprint

        let overlapCount = overlapPairCount(in: holeRegions)
        let useFastPath = overlapCount <= 1
        if useFastPath {
            applyVectorMaskFastPath(bounds: bounds, scale: resolvedScale, holes: holeRegions)
            translationBaseBounds = bounds
            translationBaseScale = resolvedScale
            translationBaseHoles = holeRegions
            stats.fastPathCount &+= 1
        } else {
            let compacted = compactHolesForSlowPath(holeRegions, scale: resolvedScale)
            applyVectorMaskSlowPath(bounds: bounds, scale: resolvedScale, holes: compacted)
            translationBaseBounds = bounds
            translationBaseScale = resolvedScale
            translationBaseHoles = compacted
            stats.slowPathCount &+= 1
        }
        stats.rebuildCount &+= 1
        stats.totalRebuildTime += Date().timeIntervalSince(rebuildStarted)
        maybeLogPipelineStats()
        PerformanceDiagnostics.increment("layer.mask_configure.hole_count", by: holeRegions.count)
        PerformanceDiagnostics.end(operationToken, operation: "layer.mask_configure")
    }

    /// Releases active masks so the overlay can revert to a solid fill.
    func reset() {
        vectorMaskLayer.path = nil
        vectorMaskLayer.isHidden = true
        vectorMaskLayer.setAffineTransform(.identity)
        frame = .zero
        renderingMode = .none
        lastGeometryFingerprint = nil
        accumulatedTranslation = .zero
        translationBaseBounds = .zero
        translationBaseScale = 1
        translationBaseHoles = []
    }

    /// Reuses existing geometry by rebuilding only translated holes while keeping full-screen coverage fixed.
    func applyTranslation(_ delta: CGVector, scale: CGFloat) -> Bool {
        guard renderingMode == .vector else { return false }
        guard vectorMaskLayer.path != nil else { return false }
        guard !translationBaseHoles.isEmpty else { return false }
        guard translationBaseBounds.width > 0, translationBaseBounds.height > 0 else { return false }
        let resolvedScale = max(scale, 1)
        let quantizedDX = (delta.dx * resolvedScale).rounded() / resolvedScale
        let quantizedDY = (delta.dy * resolvedScale).rounded() / resolvedScale
        guard quantizedDX != 0 || quantizedDY != 0 else { return false }
        accumulatedTranslation.dx += quantizedDX
        accumulatedTranslation.dy += quantizedDY
        let translatedHoles = translationBaseHoles.map { hole in
            var translated = hole
            translated.rect = hole.rect.offsetBy(dx: accumulatedTranslation.dx, dy: accumulatedTranslation.dy)
            return translated
        }
        guard let translatedPath = makeVectorMaskPathTranslated(
            bounds: translationBaseBounds,
            scale: translationBaseScale,
            holes: translatedHoles
        ) else { return false }
        vectorMaskLayer.path = translatedPath
        vectorMaskLayer.isHidden = false
        stats.fastPathCount &+= 1
        PerformanceDiagnostics.increment("layer.mask_render.translation_fast_path")
        return true
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
            holes[index].windowID = holes[index].windowID ?? candidate.windowID
            holes[index].ownerPID = holes[index].ownerPID ?? candidate.ownerPID
        } else {
            holes.append(candidate)
        }
    }

    /// Uses cached per-window shape paths and keeps holes separate when overlap pressure is low.
    private func applyVectorMaskFastPath(bounds: CGRect, scale: CGFloat, holes: [HoleRegion]) {
        guard let path = makeVectorMaskPathFastPath(bounds: bounds, scale: scale, holes: holes) else {
            reset()
            return
        }

        vectorMaskLayer.path = path
        vectorMaskLayer.isHidden = false
        renderingMode = .vector
        Self.diagnosticsTracker.recordVectorFrame()
        PerformanceDiagnostics.increment("layer.mask_render.vector")
    }

    /// Uses a conservative slow path that compacts overlap-heavy regions before rendering.
    private func applyVectorMaskSlowPath(bounds: CGRect, scale: CGFloat, holes: [HoleRegion]) {
        guard let path = makeVectorMaskPathFastPath(bounds: bounds, scale: scale, holes: holes) else {
            reset()
            return
        }

        vectorMaskLayer.path = path
        vectorMaskLayer.isHidden = false
        renderingMode = .vector
        Self.diagnosticsTracker.recordVectorFrame()
        PerformanceDiagnostics.increment("layer.mask_render.vector")
        PerformanceDiagnostics.increment("layer.mask_pipeline.slow_path")
    }

    /// Builds the even-odd vector path representing all static and dynamic carve-outs.
    private func makeVectorMaskPathFastPath(bounds: CGRect, scale: CGFloat, holes: [HoleRegion]) -> CGPath? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let path = CGMutablePath()
        path.addRect(bounds)

        for hole in holes {
            let rect = alignRectToPixelGrid(hole.rect, scale: scale, align: hole.alignToPixelGrid)
            guard rect.width > 0, rect.height > 0 else { continue }
            path.addPath(cachedWindowShapePath(for: hole, alignedRect: rect, scale: scale))
        }

        return path
    }

    /// Builds a translated path without shifting the full-screen outer coverage rect.
    private func makeVectorMaskPathTranslated(bounds: CGRect, scale: CGFloat, holes: [HoleRegion]) -> CGPath? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let path = CGMutablePath()
        path.addRect(bounds)
        for hole in holes {
            let alignedRect = alignRectToPixelGrid(hole.rect, scale: scale, align: hole.alignToPixelGrid)
            guard alignedRect.width > 0, alignedRect.height > 0 else { continue }
            let radius = min(max(hole.cornerRadius, 0), min(alignedRect.width, alignedRect.height) / 2)
            if radius > 0 {
                path.addPath(
                    CGPath(
                        roundedRect: alignedRect,
                        cornerWidth: radius,
                        cornerHeight: radius,
                        transform: nil
                    )
                )
            } else {
                path.addRect(alignedRect)
            }
        }
        return path
    }

    /// Reuses per-window hole shape geometry when frame/radius/scale are unchanged.
    private func cachedWindowShapePath(for hole: HoleRegion, alignedRect: CGRect, scale: CGFloat) -> CGPath {
        pruneWindowShapeCacheIfNeeded()
        let resolvedWindowID = hole.windowID ?? syntheticWindowIdentifier(for: hole, scale: scale)
        let key = WindowShapeCacheKey(
            windowID: resolvedWindowID,
            frameSignature: rectSignature(alignedRect, scale: 1000),
            cornerRadiusSignature: quantized(hole.cornerRadius, scale: 1000),
            titlebarStyle: hole.titlebarStyle.rawValue,
            scaleSignature: quantized(scale, scale: 1000)
        )
        if let cached = windowShapeCache[key] {
            stats.shapeCacheHits &+= 1
            PerformanceDiagnostics.recordCache(key: "window_shape_cache", hit: true)
            return cached.path
        }

        stats.shapeCacheMisses &+= 1
        PerformanceDiagnostics.recordCache(key: "window_shape_cache", hit: false)
        let radius = min(max(hole.cornerRadius, 0), min(alignedRect.width, alignedRect.height) / 2)
        let createdPath: CGPath
        if radius > 0 {
            createdPath = CGPath(
                roundedRect: alignedRect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
        } else {
            createdPath = CGPath(rect: alignedRect, transform: nil)
        }
        windowShapeCache[key] = WindowShapeCacheEntry(path: createdPath, timestamp: Date())
        if windowShapeCache.count > maximumWindowShapeCacheEntries {
            let sorted = windowShapeCache.sorted { $0.value.timestamp > $1.value.timestamp }
            windowShapeCache = Dictionary(
                uniqueKeysWithValues: sorted.prefix(maximumWindowShapeCacheEntries).map { ($0.key, $0.value) }
            )
        }
        return createdPath
    }

    /// Removes redundant contained holes before executing the slow bitmap path.
    private func compactHolesForSlowPath(_ holes: [HoleRegion], scale: CGFloat) -> [HoleRegion] {
        guard holes.count > 1 else { return holes }
        var compacted: [HoleRegion] = []
        compacted.reserveCapacity(holes.count)
        for hole in holes {
            let rect = alignRectToPixelGrid(hole.rect, scale: scale, align: hole.alignToPixelGrid)
            guard rect.width > 0, rect.height > 0 else { continue }
            if let containerIndex = compacted.firstIndex(where: { $0.rect.contains(rect) }) {
                if hole.cornerRadius > compacted[containerIndex].cornerRadius {
                    compacted[containerIndex].cornerRadius = hole.cornerRadius
                }
                continue
            }
            compacted.removeAll { rect.contains($0.rect) }
            var updatedHole = hole
            updatedHole.rect = rect
            compacted.append(updatedHole)
        }
        return compacted
    }

    /// Counts intersecting hole pairs to estimate overlap complexity.
    private func overlapPairCount(in holes: [HoleRegion]) -> Int {
        guard holes.count > 1 else { return 0 }
        var overlapCount = 0
        for leftIndex in 0..<(holes.count - 1) {
            for rightIndex in (leftIndex + 1)..<holes.count {
                if holes[leftIndex].rect.intersects(holes[rightIndex].rect) {
                    overlapCount += 1
                    if overlapCount > 4 {
                        return overlapCount
                    }
                }
            }
        }
        return overlapCount
    }

    /// Produces a stable hash for bounds/holes to detect reusable geometry state.
    private func geometryFingerprint(bounds: CGRect, scale: CGFloat, holes: [HoleRegion]) -> Int {
        var hasher = Hasher()
        hasher.combine(rectSignature(bounds, scale: 1000))
        hasher.combine(quantized(scale, scale: 1000))
        hasher.combine(holes.count)
        for hole in holes {
            hasher.combine(hole.windowID ?? syntheticWindowIdentifier(for: hole, scale: scale))
            hasher.combine(rectSignature(hole.rect, scale: 1000))
            hasher.combine(quantized(hole.cornerRadius, scale: 1000))
            hasher.combine(hole.titlebarStyle.rawValue)
        }
        return hasher.finalize()
    }

    /// Generates a synthetic deterministic ID for holes without a real window identifier.
    private func syntheticWindowIdentifier(for hole: HoleRegion, scale: CGFloat) -> Int {
        var hasher = Hasher()
        hasher.combine(rectSignature(hole.rect, scale: 1000))
        hasher.combine(quantized(hole.cornerRadius, scale: 1000))
        hasher.combine(quantized(scale, scale: 1000))
        hasher.combine(hole.titlebarStyle.rawValue)
        hasher.combine(hole.ownerPID ?? 0)
        return hasher.finalize()
    }

    /// Produces a quantized rectangle signature for hashing and cache keys.
    private func rectSignature(_ rect: CGRect, scale: CGFloat) -> Int {
        var hasher = Hasher()
        hasher.combine(quantized(rect.origin.x, scale: scale))
        hasher.combine(quantized(rect.origin.y, scale: scale))
        hasher.combine(quantized(rect.size.width, scale: scale))
        hasher.combine(quantized(rect.size.height, scale: scale))
        return hasher.finalize()
    }

    /// Quantizes floating-point values to stabilize cache signatures.
    private func quantized(_ value: CGFloat, scale: CGFloat) -> Int {
        Int((value * scale).rounded())
    }

    /// Removes stale window-shape cache entries that exceeded their lifetime.
    private func pruneWindowShapeCacheIfNeeded(referenceDate: Date = Date()) {
        let cutoff = referenceDate.addingTimeInterval(-windowShapeCacheLifetime)
        windowShapeCache = windowShapeCache.filter { $0.value.timestamp >= cutoff }
    }

    /// Periodically logs mask-layer pipeline statistics and cache hit rates.
    private func maybeLogPipelineStats(referenceDate: Date = Date()) {
        if stats.nextLogDate == .distantPast {
            stats.nextLogDate = referenceDate.addingTimeInterval(4)
            return
        }
        guard referenceDate >= stats.nextLogDate else { return }
        let totalShapeLookups = stats.shapeCacheHits + stats.shapeCacheMisses
        let hitRate: Double
        if totalShapeLookups == 0 {
            hitRate = 0
        } else {
            hitRate = (Double(stats.shapeCacheHits) / Double(totalShapeLookups)) * 100
        }
        let averageRebuildMS: Double
        if stats.rebuildCount == 0 {
            averageRebuildMS = 0
        } else {
            averageRebuildMS = (stats.totalRebuildTime / Double(stats.rebuildCount)) * 1000
        }
        logger.log(
            "mask_pipeline stats cacheHitRate=\(hitRate, format: .fixed(precision: 2), privacy: .public)% avgRebuildMs=\(averageRebuildMS, format: .fixed(precision: 3), privacy: .public) fastPath=\(self.stats.fastPathCount, privacy: .public) slowPath=\(self.stats.slowPathCount, privacy: .public)"
        )
        stats.nextLogDate = referenceDate.addingTimeInterval(4)
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
