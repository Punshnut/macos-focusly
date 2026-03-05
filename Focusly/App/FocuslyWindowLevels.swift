import AppKit
import CoreGraphics

private let focuslyOverlayBaseLevel = Int(CGWindowLevelForKey(.screenSaverWindow))

/// Window levels used by Focusly-owned windows.
enum FocuslyWindowLevels {
    /// Float Focusly UI above the screenSaver overlay so blur/tint never obscure controls.
    static let overlayBypass = NSWindow.Level(focuslyOverlayBaseLevel + 1)
}
