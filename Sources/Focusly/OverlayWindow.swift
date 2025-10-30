import AppKit
import QuartzCore

@MainActor
final class OverlayWindow: NSPanel {
    private let blurView = OverlayBlurView()

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

    private let tintMaskLayer = CAShapeLayer()
    private let blurMaskLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillRule = .evenOdd
        layer.fillColor = NSColor.white.cgColor
        layer.backgroundColor = nil
        return layer
    }()
    private var currentStyle: FocusOverlayStyle?
    private var currentMaskRectInContent: NSRect?
    private var currentMaskCornerRadius: CGFloat = 0
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
        guard let contentView else { return }

        if let rect = rectInContentView {
            let bounds = contentView.bounds
            if shouldIgnoreMask(rect: rect, in: bounds) {
                if currentMaskRectInContent == nil, currentMaskCornerRadius == 0 {
                    return
                }
                currentMaskRectInContent = nil
                currentMaskCornerRadius = 0
                clearMasks()
                return
            }
            let tolerance = maskTolerance(for: contentView)
            let resolvedCornerRadius = max(0, cornerRadius)
            if let current = currentMaskRectInContent,
               current.isApproximatelyEqual(to: rect, tolerance: tolerance),
               abs(currentMaskCornerRadius - resolvedCornerRadius) <= tolerance {
                return
            }
            currentMaskRectInContent = rect
            currentMaskCornerRadius = resolvedCornerRadius
        } else {
            if currentMaskRectInContent == nil, currentMaskCornerRadius == 0 {
                return
            }
            currentMaskRectInContent = nil
            currentMaskCornerRadius = 0
            clearMasks()
            return
        }

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
        blurView.layer?.mask = blurMaskLayer

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
        let hasDynamicMask = currentMaskRectInContent != nil
        guard hasDynamicMask || !staticExcludedRects.isEmpty else {
            clearMasks()
            return
        }

        let path = CGMutablePath()
        path.addRect(bounds)

        staticExcludedRects.forEach { path.addRect($0) }

        if let dynamic = currentMaskRectInContent {
            let resolvedRadius = min(currentMaskCornerRadius, min(dynamic.width, dynamic.height) / 2)
            if resolvedRadius > 0 {
                let rounded = CGPath(
                    roundedRect: dynamic,
                    cornerWidth: resolvedRadius,
                    cornerHeight: resolvedRadius,
                    transform: nil
                )
                path.addPath(rounded)
            } else {
                path.addRect(dynamic)
            }
        }

        tintMaskLayer.path = path
        tintMaskLayer.fillRule = .evenOdd
        tintMaskLayer.frame = bounds
        tintMaskLayer.contentsScale = backingScaleFactor
        tintView.layer?.mask = tintMaskLayer
        blurMaskLayer.path = path
        blurMaskLayer.frame = bounds
        blurMaskLayer.contentsScale = backingScaleFactor
        blurView.layer?.mask = blurMaskLayer
    }

    private func clearMasks() {
        tintView.layer?.mask = nil
        blurView.layer?.mask = nil
        blurMaskLayer.path = nil
        currentMaskCornerRadius = 0
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
