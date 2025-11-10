import Foundation

/// Stores bundle identifiers that should be ignored when resolving overlay masks.
@MainActor
final class ApplicationMaskingIgnoreList {
    private enum DefaultsKey {
        static let ignoredBundleIdentifiers = "Focusly.MaskingIgnoredBundleIdentifiers"
    }

    static let defaultBundleIdentifiers: Set<String> = []
    static let defaultProcessNameFragments: Set<String> = ["alcove"]

    private static var sharedStore = ApplicationMaskingIgnoreList(userDefaults: .standard)

    /// Shared singleton used throughout the app. Tests can instantiate their own stores as needed.
    static var shared: ApplicationMaskingIgnoreList {
        sharedStore
    }

    /// Replaces the shared store so we can reuse the caller's user defaults container.
    static func configureShared(userDefaults: UserDefaults) {
        sharedStore = ApplicationMaskingIgnoreList(userDefaults: userDefaults)
    }

    private let userDefaults: UserDefaults
    private let defaultsKey: String
    private let builtInBundleIdentifiers: Set<String>
    private let builtInProcessFragments: Set<String>
    private var persistedBundleIdentifiers: Set<String>

    init(
        userDefaults: UserDefaults,
        defaultsKey: String = DefaultsKey.ignoredBundleIdentifiers,
        builtInBundleIdentifiers: Set<String> = ApplicationMaskingIgnoreList.defaultBundleIdentifiers,
        builtInProcessNameFragments: Set<String> = ApplicationMaskingIgnoreList.defaultProcessNameFragments
    ) {
        self.userDefaults = userDefaults
        self.defaultsKey = defaultsKey
        self.builtInBundleIdentifiers = builtInBundleIdentifiers.focuslyNormalizedSet()
        self.builtInProcessFragments = builtInProcessNameFragments.focuslyNormalizedSet()

        if let storedIdentifiers = userDefaults.array(forKey: defaultsKey) as? [String] {
            persistedBundleIdentifiers = Set(storedIdentifiers.compactMap { $0.focuslyNormalizedToken() })
        } else {
            persistedBundleIdentifiers = []
        }
    }

    /// Returns every bundle identifier that will currently be ignored, combining built-in and user-defined entries.
    func ignoredBundleIdentifiers() -> Set<String> {
        builtInBundleIdentifiers.union(persistedBundleIdentifiers)
    }

    /// Returns only the bundle identifiers that were explicitly stored by the user (for future UI).
    func userDefinedBundleIdentifiers() -> Set<String> {
        persistedBundleIdentifiers
    }

    /// Adds or removes a bundle identifier from the persistent ignore list.
    func setIgnored(_ ignored: Bool, bundleIdentifier: String) {
        guard let normalized = bundleIdentifier.focuslyNormalizedToken() else { return }
        if ignored {
            if !persistedBundleIdentifiers.contains(normalized) {
                persistedBundleIdentifiers.insert(normalized)
                persistUserEntries()
            }
        } else if persistedBundleIdentifiers.remove(normalized) != nil {
            persistUserEntries()
        }
    }

    /// Determines whether a window belonging to the supplied identifier or process name should be ignored.
    func shouldIgnore(bundleIdentifier: String?, processName: String?) -> Bool {
        if let bundleIdentifier, let normalized = bundleIdentifier.focuslyNormalizedToken() {
            if builtInBundleIdentifiers.contains(normalized) || persistedBundleIdentifiers.contains(normalized) {
                return true
            }
        }

        if let processName, let normalized = processName.focuslyNormalizedToken() {
            if builtInProcessFragments.contains(where: { normalized.contains($0) }) {
                return true
            }
        }

        return false
    }

    private func persistUserEntries() {
        userDefaults.set(Array(persistedBundleIdentifiers), forKey: defaultsKey)
    }
}

extension String {
    func focuslyNormalizedToken() -> String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

extension Set where Element == String {
    func focuslyNormalizedSet() -> Set<String> {
        Set(compactMap { $0.focuslyNormalizedToken() })
    }
}
