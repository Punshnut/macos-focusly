import Foundation

/// Centralizes localization handling, including language overrides and translated strings.
@MainActor
final class LocalizationService: ObservableObject {
    /// Represents a selectable language choice exposed to the UI.
    struct LanguageOption: Identifiable, Equatable {
        static let systemID = "system"

        let id: String
        let primaryName: String
        let secondaryName: String?
        let localeIdentifier: String?

        /// Human-friendly label combining native and localized language names.
        var displayName: String {
            guard let secondaryName, secondaryName.caseInsensitiveCompare(primaryName) != .orderedSame else {
                return primaryName
            }
            return "\(primaryName) · \(secondaryName)"
        }
    }

    /// Shared singleton used by most of the app.
    static let shared = LocalizationService()

    @Published private(set) var languageOptions: [LanguageOption] = []
    @Published private(set) var locale: Locale = .autoupdatingCurrent
    @Published var languageOverrideIdentifier: String? {
        didSet {
            guard oldValue != languageOverrideIdentifier else { return }
            refreshLocaleState()
        }
    }

    private var overrideLocalizationBundle: Bundle?

    private init() {
        refreshLocaleState()
    }

    /// Returns the identifier of the selected language, falling back to the system option.
    var selectedLanguageID: String {
        languageOverrideIdentifier ?? LanguageOption.systemID
    }

    /// Looks up a localized string from the override bundle or falls back to the module localization.
    func localized(_ key: String, fallback: String? = nil, table: String? = nil) -> String {
        let bundle = overrideLocalizationBundle ?? .focuslyResources
        return bundle.localizedString(forKey: key, value: fallback ?? key, table: table)
    }

    /// Lets callers select a language by identifier, handling reset to system defaults.
    func selectLanguage(id: String) {
        if id == LanguageOption.systemID {
            languageOverrideIdentifier = nil
        } else {
            languageOverrideIdentifier = id
        }
    }

    /// Retrieves the matching language option metadata for the given ID.
    func option(for id: String) -> LanguageOption? {
        languageOptions.first(where: { $0.id == id })
    }

    /// Updates the locale, available options, and localized bundle after a language change.
    private func refreshLocaleState() {
        let displayLocale: Locale
        if let identifier = languageOverrideIdentifier,
           let bundle = LocalizationService.bundle(for: identifier) {
            overrideLocalizationBundle = bundle
            displayLocale = Locale(identifier: identifier)
        } else {
            overrideLocalizationBundle = nil
            displayLocale = .autoupdatingCurrent
        }

        let sortingLocale = Locale.autoupdatingCurrent
        locale = displayLocale
        languageOptions = LocalizationService.makeLanguageOptions(
            displayLocale: displayLocale,
            sortingLocale: sortingLocale,
            translator: { [weak self] key, fallback in
                self?.localized(key, fallback: fallback) ?? (fallback ?? key)
            }
        )
    }

    /// Returns a localized bundle for the exact identifier or falls back to language code only.
    private static func bundle(for identifier: String) -> Bundle? {
        if let path = Bundle.focuslyResources.path(forResource: identifier, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        if let languageCode = identifier.split(separator: "-").first {
            let trimmed = String(languageCode)
            if let path = Bundle.focuslyResources.path(forResource: trimmed, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }

    /// Produces language option models using the available `.lproj` folders in the bundle.
    private static func makeLanguageOptions(
        displayLocale: Locale,
        sortingLocale: Locale,
        translator: (String, String?) -> String
    ) -> [LanguageOption] {
        var options: [LanguageOption] = []

        let systemTitle = translator(
            "Follow macOS Language (Default)",
            "Follow macOS Language (Default)"
        )
        options.append(LanguageOption(
            id: LanguageOption.systemID,
            primaryName: systemTitle,
            secondaryName: nil,
            localeIdentifier: nil
        ))

        let available = Bundle.focuslyResources.localizations
            .filter { $0.caseInsensitiveCompare("Base") != .orderedSame }

        let collationIdentifier: String?
        if #available(macOS 13, *) {
            collationIdentifier = sortingLocale.collation.identifier
        } else {
            collationIdentifier = sortingLocale.collationIdentifier
        }
        let collation = collationIdentifier.flatMap(Locale.init(identifier:)) ?? sortingLocale

        let mapped: [LanguageOption] = available.map { identifier in
            let nativeLocale = Locale(identifier: identifier)
            let primary = nativeLocale.localizedString(forIdentifier: identifier) ?? identifier
            let localized = displayLocale.localizedString(forIdentifier: identifier) ?? primary
            let secondary = primary.caseInsensitiveCompare(localized) == .orderedSame ? nil : localized
            return LanguageOption(
                id: identifier,
                primaryName: primary,
                secondaryName: secondary,
                localeIdentifier: identifier
            )
        }

        options.append(contentsOf: mapped.sorted { lhs, rhs in
            lhs.primaryName.compare(
                rhs.primaryName,
                options: [.caseInsensitive],
                range: nil,
                locale: collation
            ) == .orderedAscending
        })

        return options
    }
}
