import AppKit
import CoreImage
import QuartzCore

@MainActor
final class OverlayWindow: NSPanel {
    private let effectView = NSVisualEffectView()
    private let tintView = NSView()
    private var screenID: DisplayID = 0

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

        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.translatesAutoresizingMaskIntoConstraints = false

        tintView.wantsLayer = true
        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.layer?.cornerRadius = 0

        let rootView = NSView(frame: frame)
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layerUsesCoreImageFilters = true
        contentView = rootView

        rootView.addSubview(effectView)
        effectView.addSubview(tintView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: rootView.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: effectView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])
    }

    func apply(style: FocusOverlayStyle, animated: Bool) {
        let updates = {
            self.alphaValue = style.opacity
            self.effectView.state = .active
            self.effectView.wantsLayer = true
            self.effectView.layer?.cornerCurve = .continuous
            self.tintView.layer?.backgroundColor = style.tint.makeColor().cgColor
            self.tintView.layer?.compositingFilter = "multiplyBlendMode"
            self.contentView?.layer?.cornerRadius = 0
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(style.blurRadius, forKey: kCIInputRadiusKey)
                self.contentView?.layer?.backgroundFilters = [blur]
            } else {
                self.contentView?.layer?.backgroundFilters = []
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = style.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                updates()
            }
        } else {
            updates()
        }
    }

    func updateFrame(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
        contentView?.frame = screen.frame
    }

    func associatedDisplayID() -> DisplayID {
        screenID
    }
}
