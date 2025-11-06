import AppKit
import CoreGraphics

private let focuslyOverlayBaseLevel = Int(CGWindowLevelForKey(.screenSaverWindow))

/// Centralized window level definitions for Focusly-hosted windows.
enum FocuslyWindowLevels {
    /// Keep the preferences window at a standard level so overlay masking can track it.
    static let overlayBypass: NSWindow.Level = .normal
    /// Ensure the macOS About panel still floats above overlay content.
    static let aboutPanel = NSWindow.Level(focuslyOverlayBaseLevel + 2)
}
