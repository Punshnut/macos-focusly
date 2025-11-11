import AppKit
import Foundation

/// Stores bundle identifiers that should be ignored when resolving overlay masks.
@MainActor
final class ApplicationMaskingIgnoreList {
    enum Preference: String, Codable, CaseIterable, Identifiable {
        case excludeCompletely
        case excludeExceptSettingsWindow
        case alwaysMask

        var id: String { rawValue }
    }

    struct Entry: Codable, Hashable {
        var bundleIdentifier: String
        var preference: Preference
    }

    private enum DefaultsKey {
        static let ignoredBundleIdentifiers = "Focusly.MaskingIgnoredBundleIdentifiers"
        static let ignoredBundleEntries = "Focusly.MaskingIgnoredBundleEntries"
    }

    static let defaultBundleEntryPreferences: [String: Preference] = [:]
    static let defaultProcessNameFragmentPreferences: [String: Preference] = [
        "alcove": .excludeExceptSettingsWindow
    ]
    private static let settingsKeywordFragments: [String] = [
        "settings",
        "preference",
        "preferences",
        "préférence",
        "préférences",
        "präferenz",
        "präferenzen",
        "einstellung",
        "einstellungen",
        "option",
        "optionen",
        "paramètre",
        "paramètres",
        "parametro",
        "parametros",
        "configuracion",
        "configuración",
        "configuraciones",
        "configuracao",
        "configuração",
        "configurações",
        "configuration",
        "konfiguration",
        "impostazione",
        "impostazioni",
        "instelling",
        "instellingen",
        "настройки",
        "настройка",
        "设置",
        "設定"
    ]

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
    private let builtInBundlePreferences: [String: Preference]
    private let builtInBundleIdentifiers: Set<String>
    private let builtInProcessFragmentPreferences: [String: Preference]
    private var persistedEntries: [String: Entry]

    init(
        userDefaults: UserDefaults,
        defaultsKey: String = DefaultsKey.ignoredBundleIdentifiers,
        builtInBundleEntries: [String: Preference] = ApplicationMaskingIgnoreList.defaultBundleEntryPreferences,
        builtInProcessNameFragmentPreferences: [String: Preference] = ApplicationMaskingIgnoreList.defaultProcessNameFragmentPreferences
    ) {
        self.userDefaults = userDefaults
        self.defaultsKey = defaultsKey
        self.builtInBundlePreferences = ApplicationMaskingIgnoreList.normalizePreferences(builtInBundleEntries)
        self.builtInBundleIdentifiers = Set(self.builtInBundlePreferences.keys)
        self.builtInProcessFragmentPreferences = ApplicationMaskingIgnoreList.normalizePreferences(builtInProcessNameFragmentPreferences)

        if let data = userDefaults.data(forKey: DefaultsKey.ignoredBundleEntries),
           let decoded = try? PropertyListDecoder().decode([Entry].self, from: data) {
            persistedEntries = ApplicationMaskingIgnoreList.normalizeEntries(decoded)
        } else if let storedIdentifiers = userDefaults.array(forKey: defaultsKey) as? [String] {
            let legacyEntries = storedIdentifiers.map {
                Entry(bundleIdentifier: $0, preference: .excludeCompletely)
            }
            persistedEntries = ApplicationMaskingIgnoreList.normalizeEntries(legacyEntries)
            persistUserEntries()
        } else {
            persistedEntries = [:]
        }
    }

    /// Returns every bundle identifier that will currently be ignored, combining built-in and user-defined entries.
    func ignoredBundleIdentifiers() -> Set<String> {
        let userDefined = Set(persistedEntries.keys)
        return builtInBundleIdentifiers.union(userDefined)
    }

    /// Returns only the bundle identifiers that were explicitly stored by the user (for future UI).
    func userDefinedBundleIdentifiers() -> Set<String> {
        Set(persistedEntries.keys)
    }

    /// Returns the persisted entry metadata for user-defined applications.
    func userEntries() -> [Entry] {
        Array(persistedEntries.values)
    }

    /// Returns built-in entries detected from currently running applications (e.g. Alcove).
    func activeBuiltInEntries() -> [Entry] {
        let runningApplications = NSWorkspace.shared.runningApplications
        var resolved: [String: Entry] = [:]
        for application in runningApplications {
            guard let bundleIdentifier = application.bundleIdentifier,
                  let normalized = bundleIdentifier.focuslyNormalizedToken() else {
                continue
            }
            if resolved[normalized] != nil {
                continue
            }
            if let preference = builtInBundlePreferences[normalized] {
                resolved[normalized] = Entry(bundleIdentifier: bundleIdentifier, preference: preference)
                continue
            }
            if let name = application.localizedName?.focuslyNormalizedToken() {
                for (fragment, preference) in builtInProcessFragmentPreferences where name.contains(fragment) {
                    resolved[normalized] = Entry(bundleIdentifier: bundleIdentifier, preference: preference)
                    break
                }
            }
        }
        return Array(resolved.values)
    }

    /// Adds or removes a bundle identifier from the persistent ignore list.
    func setIgnored(_ ignored: Bool, bundleIdentifier: String) {
        if ignored {
            setPreference(.excludeCompletely, bundleIdentifier: bundleIdentifier)
        } else {
            removeEntry(bundleIdentifier: bundleIdentifier)
        }
    }

    /// Adds or updates a more granular preference state for an application.
    func setPreference(_ preference: Preference, bundleIdentifier: String) {
        guard let normalized = bundleIdentifier.focuslyNormalizedToken() else { return }
        persistedEntries[normalized] = Entry(bundleIdentifier: bundleIdentifier, preference: preference)
        persistUserEntries()
    }

    /// Removes a stored application entry entirely.
    func removeEntry(bundleIdentifier: String) {
        guard let normalized = bundleIdentifier.focuslyNormalizedToken() else { return }
        if persistedEntries.removeValue(forKey: normalized) != nil {
            persistUserEntries()
        }
    }

    /// Determines whether a window belonging to the supplied identifier or process name should be ignored.
    func shouldIgnore(bundleIdentifier: String?, processName: String?, windowName: String? = nil) -> Bool {
        if let bundleIdentifier, let normalized = bundleIdentifier.focuslyNormalizedToken() {
            if let entry = persistedEntries[normalized] {
                return shouldIgnore(preference: entry.preference, windowName: windowName)
            } else if let builtInPreference = builtInBundlePreferences[normalized] {
                return shouldIgnore(preference: builtInPreference, windowName: windowName)
            } else if builtInBundleIdentifiers.contains(normalized) {
                return true
            }
        }

        if let processName, let normalized = processName.focuslyNormalizedToken() {
            for (fragment, preference) in builtInProcessFragmentPreferences {
                if normalized.contains(fragment) {
                    return shouldIgnore(preference: preference, windowName: windowName)
                }
            }
        }

        return false
    }

    private func persistUserEntries() {
        let entries = Array(persistedEntries.values)
        if entries.isEmpty {
            userDefaults.removeObject(forKey: DefaultsKey.ignoredBundleEntries)
            userDefaults.removeObject(forKey: defaultsKey)
            return
        }

        if let data = try? PropertyListEncoder().encode(entries) {
            userDefaults.set(data, forKey: DefaultsKey.ignoredBundleEntries)
        }
        userDefaults.set(entries.map(\.bundleIdentifier), forKey: defaultsKey)
    }

    private static func isLikelySettingsWindow(_ windowName: String) -> Bool {
        let normalized = windowName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return settingsKeywordFragments.contains { normalized.contains($0) }
    }

    private static func normalizeEntries(_ entries: [Entry]) -> [String: Entry] {
        var normalizedEntries: [String: Entry] = [:]
        for entry in entries {
            guard let normalized = entry.bundleIdentifier.focuslyNormalizedToken() else { continue }
            normalizedEntries[normalized] = entry
        }
        return normalizedEntries
    }

    private static func normalizePreferences(_ preferences: [String: Preference]) -> [String: Preference] {
        var normalized: [String: Preference] = [:]
        for (identifier, preference) in preferences {
            guard let normalizedKey = identifier.focuslyNormalizedToken() else { continue }
            normalized[normalizedKey] = preference
        }
        return normalized
    }
}

private extension ApplicationMaskingIgnoreList {
    func shouldIgnore(preference: Preference, windowName: String?) -> Bool {
        switch preference {
        case .excludeCompletely:
            return true
        case .excludeExceptSettingsWindow:
            if let windowName,
               ApplicationMaskingIgnoreList.isLikelySettingsWindow(windowName) {
                return false
            }
            return true
        case .alwaysMask:
            return false
        }
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
