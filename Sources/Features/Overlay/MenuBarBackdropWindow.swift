import AppKit

/// Thin overlay that sits behind the system menu bar to provide blur and tint while keeping status items sharp.
@MainActor
final class MenuBarBackdropWindow: NSPanel {
    private let blurView = OverlayBlurView()
    private let tintView: NSView = {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        let layer = CALayer()
        layer.isOpaque = false
        layer.backgroundColor = NSColor.clear.cgColor
        view.layer = layer
        return view
    }()

    private var currentStyle: FocusOverlayStyle?
    private var areFiltersActive = true
    private(set) var displayID: DisplayID

    init(screen: NSScreen, displayID: DisplayID) {
        self.displayID = displayID
        let frame = MenuBarBackdropWindow.menuBarFrame(for: screen) ?? .zero
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = false
        hidesOnDeactivate = false
        worksWhenModal = true
        configureWindow()
        configureContent()
        updateFrame(to: screen)
    }

    convenience init(screen: NSScreen) {
        let resolvedDisplayID = MenuBarBackdropWindow.resolveDisplayIdentifier(for: screen)
        self.init(screen: screen, displayID: resolvedDisplayID)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Ensures the backdrop is ready to fade in without stale animations.
    func prepareForPresentation() {
        alphaValue = 0
        blurView.prepareForReuse()
        tintView.layer?.removeAllAnimations()
        contentView?.layer?.removeAllAnimations()
    }

    /// Fades the window in when the backdrop becomes visible.
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

    /// Hides the backdrop, optionally animating the fade-out.
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

    /// Enables or disables blur/tint filters across the backdrop.
    func setFiltersEnabled(_ enabled: Bool, animated: Bool) {
        guard areFiltersActive != enabled else { return }
        areFiltersActive = enabled

        let targetOpacity = CGFloat(max(0, min(currentStyle?.opacity ?? 1, 1)))
        let duration = animated ? max(0, currentStyle?.animationDuration ?? 0.25) : 0

        if enabled {
            blurView.setBlurEnabled(true)
            tintView.isHidden = false

            guard duration > 0 else {
                blurView.alphaValue = targetOpacity
                tintView.alphaValue = targetOpacity
                return
            }

            blurView.alphaValue = 0
            tintView.alphaValue = 0

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.blurView.animator().alphaValue = targetOpacity
                self.tintView.animator().alphaValue = targetOpacity
            }
        } else {
            let applyDisabledState = {
                self.blurView.setBlurEnabled(false)
                self.tintView.isHidden = true
            }

            guard duration > 0 else {
                blurView.alphaValue = 0
                tintView.alphaValue = 0
                applyDisabledState()
                return
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.completionHandler = applyDisabledState
                self.blurView.animator().alphaValue = 0
                self.tintView.animator().alphaValue = 0
            }
        }
    }

    /// Applies the supplied overlay style to the backdrop.
    func apply(style: FocusOverlayStyle, animated: Bool) {
        currentStyle = style

        tintView.layer?.backgroundColor = style.tint.makeColor().cgColor
        blurView.setMaterial(style.blurMaterial.visualEffectMaterial)
        blurView.setExtraBlurRadius(CGFloat(max(0, style.blurRadius)))
        blurView.setColorTreatment(style.colorTreatment)

        guard areFiltersActive else { return }

        let targetOpacity = CGFloat(max(0, min(style.opacity, 1)))

        guard animated else {
            blurView.alphaValue = targetOpacity
            tintView.alphaValue = targetOpacity
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = style.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.blurView.animator().alphaValue = targetOpacity
            self.tintView.animator().alphaValue = targetOpacity
        }
    }

    /// Updates the backdrop geometry to match the target screen's menu bar.
    func updateFrame(to screen: NSScreen) {
        guard let frame = MenuBarBackdropWindow.menuBarFrame(for: screen) else {
            setFrame(.zero, display: false)
            return
        }
        setFrame(frame, display: true)
    }

    /// Returns the cached CoreGraphics display identifier used to map back to a screen.
    func associatedDisplayID() -> DisplayID {
        displayID
    }

    private func configureWindow() {
        let statusLevel = NSWindow.Level.statusBar
        level = NSWindow.Level(rawValue: statusLevel.rawValue - 1)
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

    private static func menuBarFrame(for screen: NSScreen) -> NSRect? {
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let height = max(0, screenFrame.maxY - visibleFrame.maxY)
        guard height > 0 else { return nil }
        return NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - height,
            width: screenFrame.width,
            height: height
        )
    }

    private static func resolveDisplayIdentifier(for screen: NSScreen) -> DisplayID {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return 0
        }
        return DisplayID(truncating: number)
    }
}
