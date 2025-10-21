import AppKit
import CoreImage
import QuartzCore

@MainActor
final class OverlayWindow: NSPanel {
    private let blurView = OverlayBlurView()
    private let tintView = NSView()
    private var screenID: DisplayID = 0
    private var currentStyle: FocusOverlayStyle?

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        configureWindow()
    }

    convenience init(screen: NSScreen, screenID: DisplayID) {
        self.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.screenID = screenID
        setFrame(screen.frame, display: false)
    }

    private func configureWindow() {
        let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        level = NSWindow.Level(rawValue: desktopLevel + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]

        blurView.translatesAutoresizingMaskIntoConstraints = false

        tintView.wantsLayer = true
        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.layer?.cornerRadius = 0
        tintView.layer?.backgroundColor = NSColor.clear.cgColor
        tintView.layer?.compositingFilter = "multiplyBlendMode"
        tintView.alphaValue = 1.0

        let rootView = NSView(frame: frame)
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = rootView

        rootView.addSubview(blurView)
        rootView.addSubview(tintView)

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: rootView.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: rootView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
    }

    func apply(style: FocusOverlayStyle, animated: Bool) {
        currentStyle = style

        let targetOpacity = style.opacity
        let targetColor = style.tint.makeColor().cgColor
        let duration = style.animationDuration

        blurView.setBlurRadius(style.blurRadius, animated: animated, duration: duration)

        let updateWindowOpacity = {
            self.alphaValue = targetOpacity
        }

        let updateTint = {
            self.tintView.layer?.backgroundColor = targetColor
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().alphaValue = targetOpacity
            }

            CATransaction.begin()
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            CATransaction.setDisableActions(false)
            updateTint()
            CATransaction.commit()
        } else {
            updateWindowOpacity()
            updateTint()
        }
    }

    func updateFrame(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
        contentView?.frame = screen.frame
    }

    func prepareForPresentation() {
        alphaValue = 0
        tintView.layer?.removeAllAnimations()
        contentView?.layer?.removeAllAnimations()
        blurView.layer?.removeAllAnimations()
    }

    func hide(animated: Bool) {
        let duration = currentStyle?.animationDuration ?? 0.25
        guard animated else {
            tintView.layer?.removeAllAnimations()
            blurView.layer?.removeAllAnimations()
            alphaValue = 0
            orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.completionHandler = { [weak self] in
                guard let self else { return }
                self.blurView.layer?.removeAllAnimations()
                self.alphaValue = 0
                self.orderOut(nil)
            }
            self.animator().alphaValue = 0
        }
    }

    func associatedDisplayID() -> DisplayID {
        screenID
    }
}

private final class OverlayBlurView: NSView {
    private let blurFilter = CIFilter(name: "CIGaussianBlur")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        blurFilter?.setDefaults()

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

    func setBlurRadius(_ radius: Double, animated: Bool, duration: TimeInterval) {
        guard let layer else { return }

        guard let blurFilter else {
            layer.backgroundFilters = nil
            return
        }

        let clampedRadius = max(0, radius)
        blurFilter.setValue(clampedRadius, forKey: kCIInputRadiusKey)

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        layer.backgroundFilters = clampedRadius > 0 ? [blurFilter] : []
        CATransaction.commit()
    }
}
