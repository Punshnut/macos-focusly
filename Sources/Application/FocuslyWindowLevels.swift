import AppKit
import CoreGraphics

private let focuslyOverlayBaseLevel = Int(CGWindowLevelForKey(.screenSaverWindow))

/// Centralized window level definitions so Focusly windows consistently appear above overlay masks.
enum FocuslyWindowLevels {
    /// Keeps the preferences window visible above the blur overlay.
    static let overlayBypass = NSWindow.Level(focuslyOverlayBaseLevel + 1)
    /// Ensures the macOS About panel also floats above the preferences window.
    static let aboutPanel = NSWindow.Level(focuslyOverlayBaseLevel + 2)
}
