import AppKit
import CoreGraphics

private let focuslyOverlayBaseLevel = Int(CGWindowLevelForKey(.screenSaverWindow))

/// Centralized window level definitions for Focusly-hosted windows.
enum FocuslyWindowLevels {
    /// Float Focusly UI above the screenSaver overlay so blur/tint never obscure controls.
    static let overlayBypass = NSWindow.Level(focuslyOverlayBaseLevel + 1)
}
