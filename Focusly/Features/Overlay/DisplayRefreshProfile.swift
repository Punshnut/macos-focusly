import AppKit
import CoreGraphics
import QuartzCore

/// Summarizes the refresh characteristics of a display so overlay rendering can
/// adapt its sampling cadence to match the host hardware.
struct DisplayRefreshProfile: Equatable {
    let displayID: DisplayID
    let nominalFramesPerSecond: Double
    let maximumFramesPerSecond: Double
    let isBuiltIn: Bool
    let usesVariableRefreshRate: Bool

    /// Highest refresh rate we can confidently target for this display.
    var preferredFramesPerSecond: Double {
        let resolved = max(maximumFramesPerSecond, nominalFramesPerSecond)
        return resolved > 0 ? resolved : 60
    }

    /// Frame interval derived from the preferred refresh rate.
    var preferredFrameInterval: TimeInterval {
        1.0 / preferredFramesPerSecond
    }

    /// Whether we should bias mask prediction to land one frame ahead.
    var wantsFrameAheadPrediction: Bool {
        if usesVariableRefreshRate && isBuiltIn {
            return true
        }
        if isBuiltIn && maximumFramesPerSecond >= 100 {
            return true
        }
        return false
    }

    /// Lead time that roughly equals one frame for the host panel.
    var recommendedPredictionLead: TimeInterval {
        preferredFrameInterval
    }

    /// Whether this panel benefits from a constantly running display link so predictions stay ahead.
    var prefersPersistentDisplayLink: Bool {
        if usesVariableRefreshRate && isBuiltIn {
            return true
        }
        if isBuiltIn && maximumFramesPerSecond >= 100 {
            return true
        }
        if maximumFramesPerSecond >= 144 {
            return true
        }
        return false
    }

    /// Displays that animate windows directly into Stage Manager or dock transitions need continuous prediction.
    var demandsContinuousPrediction: Bool {
        if usesVariableRefreshRate && isBuiltIn {
            return true
        }
        if isBuiltIn && preferredFramesPerSecond >= 100 {
            return true
        }
        if preferredFramesPerSecond >= 165 {
            return true
        }
        return false
    }

    /// Preferred Core Animation frame-rate hints tailored to the display's capabilities.
    @available(macOS 12.0, *)
    var preferredFrameRateRange: CAFrameRateRange {
        let preferred = max(preferredFramesPerSecond, 60)
        let minimum: Double
        if usesVariableRefreshRate {
            minimum = max(60, preferred * 0.65)
        } else if preferred >= 120 {
            minimum = preferred * 0.75
        } else {
            minimum = preferred * 0.8
        }
        let maximum = min(240, max(preferred * 1.35, preferred * 1.1))
        return CAFrameRateRange(
            minimum: Float(minimum),
            maximum: Float(maximum),
            preferred: Float(preferred)
        )
    }
}

/// Produces refresh profiles for displays using CoreGraphics and AppKit metadata.
enum DisplayRefreshEstimator {
    /// Attempts to build a profile for the provided display identifier.
    static func profile(for displayID: DisplayID, screen: NSScreen? = nil) -> DisplayRefreshProfile? {
        guard displayID != 0 else { return nil }
        let resolvedScreen = screen ?? self.screen(for: displayID)
        let nominalRefreshRate = self.nominalRefreshRate(for: displayID)
        let screenMaximum = maximumFramesPerSecond(for: resolvedScreen)
        let peakModeRefresh = peakRefreshRateFromAvailableModes(for: displayID)
        var detectedMaximum = max(nominalRefreshRate, max(screenMaximum, peakModeRefresh))
        detectedMaximum = heuristicallyBoostedRefreshRate(for: displayID, candidate: detectedMaximum)
        let fallbackMaximum = detectedMaximum > 0 ? detectedMaximum : 60
        let isBuiltIn = CGDisplayIsBuiltin(CGDirectDisplayID(displayID)) != 0
        let usesVariableRefreshRate = resolvesVariableRefreshSupport(
            displayID: displayID,
            nominalRefresh: nominalRefreshRate,
            screenMaximum: screenMaximum,
            detectedMaximum: detectedMaximum
        )

        return DisplayRefreshProfile(
            displayID: displayID,
            nominalFramesPerSecond: nominalRefreshRate,
            maximumFramesPerSecond: fallbackMaximum,
            isBuiltIn: isBuiltIn,
            usesVariableRefreshRate: usesVariableRefreshRate
        )
    }

    /// Returns the AppKit `NSScreen` associated with the given display identifier, if any.
    private static func screen(for displayID: DisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return DisplayID(truncating: number) == displayID
        }
    }

    /// Resolves the nominal refresh rate reported by CoreGraphics, if available.
    private static func nominalRefreshRate(for displayID: DisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(displayID)) else { return 0 }
        let refreshRate = mode.refreshRate
        return refreshRate.isFinite && refreshRate > 0 ? refreshRate : 0
    }

    /// Resolves the highest refresh rate AppKit reports for a given screen.
    private static func maximumFramesPerSecond(for screen: NSScreen?) -> Double {
        guard let screen else { return 0 }
        if #available(macOS 12.0, *) {
            let maximum = Double(screen.maximumFramesPerSecond)
            return maximum > 0 ? maximum : 0
        }
        return 0
    }

    /// Returns the highest refresh rate advertised by any compatible display mode.
    private static func peakRefreshRateFromAvailableModes(for displayID: DisplayID) -> Double {
        guard let allModes = CGDisplayCopyAllDisplayModes(CGDirectDisplayID(displayID), nil) as? [CGDisplayMode] else {
            return 0
        }
        var peak: Double = 0
        for mode in allModes {
            let refreshRate = mode.refreshRate
            guard refreshRate.isFinite, refreshRate > 0 else { continue }
            peak = max(peak, refreshRate)
        }
        return peak
    }

    /// Boosts refresh-rate estimates for built-in ProMotion panels that report `0 Hz` at rest.
    private static func heuristicallyBoostedRefreshRate(for displayID: DisplayID, candidate: Double) -> Double {
        var resolved = candidate
        guard resolved < 100 else { return resolved }
        guard CGDisplayIsBuiltin(CGDirectDisplayID(displayID)) != 0 else { return resolved }
        guard HardwareCapabilities.isAppleSilicon else { return resolved }

        let pixelWidth = CGDisplayPixelsWide(CGDirectDisplayID(displayID))
        if pixelWidth >= 3000 {
            resolved = max(resolved, 120)
        }
        return resolved
    }

    /// Determines whether a display should be treated as VRR even if CoreGraphics reports `0 Hz`.
    private static func resolvesVariableRefreshSupport(
        displayID: DisplayID,
        nominalRefresh: Double,
        screenMaximum: Double,
        detectedMaximum: Double
    ) -> Bool {
        if nominalRefresh <= 0 && screenMaximum > 0 {
            return true
        }
        if nominalRefresh <= 0,
           detectedMaximum >= 100,
           CGDisplayIsBuiltin(CGDirectDisplayID(displayID)) != 0 {
            return true
        }
        return false
    }
}
