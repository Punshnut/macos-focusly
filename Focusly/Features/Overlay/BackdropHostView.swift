import AppKit
import QuartzCore

/// Lightweight host for a window-server-backed backdrop layer (uses CABackdropLayer when available).
/// Falls back to an empty layer if the private class is unavailable at runtime.
@MainActor
final class BackdropHostView: NSView {
    private static let backdropLayerClass: CALayer.Type? = NSClassFromString("CABackdropLayer") as? CALayer.Type
    static let isSupported: Bool = backdropLayerClass != nil

    private var backdropLayer: CALayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerUsesCoreImageFilters = false
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        configureBackdropLayer()
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Adjusts blur strength when the backdrop layer understands the selector.
    func setBlurRadius(_ radius: CGFloat) {
        guard let backdropLayer else { return }
        let selector = NSSelectorFromString("setBlurRadius:")
        if backdropLayer.responds(to: selector) {
            _ = backdropLayer.perform(selector, with: radius)
        } else {
            backdropLayer.setValue(radius, forKey: "blurRadius")
        }
    }

    /// Enables or disables the backdrop; safest toggle is visibility.
    func setEnabled(_ enabled: Bool) {
        isHidden = !enabled
        backdropLayer?.isHidden = !enabled
    }

    override func layout() {
        super.layout()
        backdropLayer?.frame = bounds
    }

    private func configureBackdropLayer() {
        guard let backdropType = Self.backdropLayerClass else { return }
        let layer = backdropType.init()
        layer.frame = bounds
        layer.masksToBounds = false
        layer.isGeometryFlipped = false
        layer.isOpaque = false
        layer.needsDisplayOnBoundsChange = true

        // Best-effort window-server awareness; guard with selector checks to avoid crashes.
        let windowServerSelector = NSSelectorFromString("setWindowServerAware:")
        if layer.responds(to: windowServerSelector) {
            _ = layer.perform(windowServerSelector, with: true)
        }

        self.layer?.addSublayer(layer)
        self.backdropLayer = layer
    }
}
