import Foundation

@MainActor
final class LocalizationService: ObservableObject {
    struct LanguageOption: Identifiable, Equatable {
        static let systemID = "system"

        let id: String
        let primaryName: String
        let secondaryName: String?
        let localeIdentifier: String?

        var displayName: String {
            guard let secondaryName, secondaryName.caseInsensitiveCompare(primaryName) != .orderedSame else {
                return primaryName
            }
            return "\(primaryName) · \(secondaryName)"
        }
    }

    static let shared = LocalizationService()

    @Published private(set) var languageOptions: [LanguageOption] = []
    @Published private(set) var locale: Locale = .autoupdatingCurrent
    @Published var overrideIdentifier: String? {
        didSet {
            guard oldValue != overrideIdentifier else { return }
            updateLocale()
        }
    }

    private var overrideBundle: Bundle?

    private init() {
        updateLocale()
    }

    var selectedLanguageID: String {
        overrideIdentifier ?? LanguageOption.systemID
    }

    func localized(_ key: String, fallback: String? = nil, table: String? = nil) -> String {
        let bundle = overrideBundle ?? .module
        return bundle.localizedString(forKey: key, value: fallback ?? key, table: table)
    }

    func selectLanguage(id: String) {
        if id == LanguageOption.systemID {
            overrideIdentifier = nil
        } else {
            overrideIdentifier = id
        }
    }

    func option(for id: String) -> LanguageOption? {
        languageOptions.first(where: { $0.id == id })
    }

    private func updateLocale() {
        if let identifier = overrideIdentifier,
           let bundle = LocalizationService.bundle(for: identifier) {
            overrideBundle = bundle
            locale = Locale(identifier: identifier)
        } else {
            overrideBundle = nil
            locale = .autoupdatingCurrent
        }
        languageOptions = LocalizationService.makeLanguageOptions(
            locale: locale,
            translator: { [weak self] key, fallback in
                self?.localized(key, fallback: fallback) ?? (fallback ?? key)
            }
        )
    }

    private static func bundle(for identifier: String) -> Bundle? {
        if let path = Bundle.module.path(forResource: identifier, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        if let languageCode = identifier.split(separator: "-").first {
            let trimmed = String(languageCode)
            if let path = Bundle.module.path(forResource: trimmed, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }

    private static func makeLanguageOptions(
        locale: Locale,
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

        let available = Bundle.module.localizations
            .filter { $0.caseInsensitiveCompare("Base") != .orderedSame }

        let currentLocale = locale
        let collationIdentifier: String?
        if #available(macOS 13, *) {
            collationIdentifier = currentLocale.collation.identifier
        } else {
            collationIdentifier = currentLocale.collationIdentifier
        }
        let collation = collationIdentifier.flatMap(Locale.init(identifier:)) ?? currentLocale

        let mapped: [LanguageOption] = available.map { identifier in
            let nativeLocale = Locale(identifier: identifier)
            let primary = nativeLocale.localizedString(forIdentifier: identifier) ?? identifier
            let localized = currentLocale.localizedString(forIdentifier: identifier) ?? primary
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
