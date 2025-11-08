import Foundation

/// Provides a resilient way to locate the SwiftPM-generated resource bundle at runtime.
extension Bundle {
    private final class FocuslyBundleFinder {}

    /// Shared bundle containing the app's localized strings and assets.
    static let focuslyResources: Bundle = {
        let bundleName = "Focusly_Focusly"
        let bundleFilename = "\(bundleName).bundle"

        // SwiftPM usually places the bundle next to the executable or inside the resources folder.
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle(for: FocuslyBundleFinder.self).resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: FocuslyBundleFinder.self).bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle(for: FocuslyBundleFinder.self).executableURL?.deletingLastPathComponent()
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            let bundleURL = candidate.appendingPathComponent(bundleFilename)
            if let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }

        // Fall back to any already-loaded bundles that match, otherwise return the main bundle.
        if let loaded = (Bundle.allBundles + Bundle.allFrameworks).first(where: { bundle in
            bundle.bundleURL.lastPathComponent == bundleFilename
        }) {
            return loaded
        }

        return .main
    }()
}
