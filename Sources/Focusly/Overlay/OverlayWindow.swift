import AppKit
import CoreImage
import QuartzCore

@MainActor
final class OverlayWindow: NSPanel {
    private let effectView = NSVisualEffectView()
    private let tintView = NSView()
    private let screenID: DisplayID

    init(screen: NSScreen, screenID: DisplayID) {
        self.screenID = screenID
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
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

        contentView = NSView(frame: screen.frame)
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        contentView?.layerUsesCoreImageFilters = true
        contentView?.addSubview(effectView)
        effectView.addSubview(tintView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: contentView!.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
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
    }

    func associatedDisplayID() -> DisplayID {
        screenID
    }
}
