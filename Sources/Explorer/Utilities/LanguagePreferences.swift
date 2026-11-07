import Foundation

enum InterfaceLanguage: String, CaseIterable {
    case russian = "ru"
    case english = "en"
    case spanish = "es"

    var nativeName: String {
        switch self {
        case .russian: "Русский"
        case .english: "English"
        case .spanish: "Español"
        }
    }
}

struct LanguagePreferences {
    static let appleLanguagesKey = "AppleLanguages"

    let defaults: UserDefaults
    let domain: String?

    init(defaults: UserDefaults = .standard, domain: String? = Bundle.main.bundleIdentifier) {
        self.defaults = defaults
        self.domain = domain
    }

    var selection: InterfaceLanguage? {
        get {
            guard let languages = appLanguageOverride as? [String] else { return nil }
            return Self.firstSupportedLanguage(in: languages)?.language
        }
        nonmutating set {
            // The app and AppKit share the same preference for the next launch.
            defaults.set(newValue.map { [$0.rawValue] }, forKey: Self.appleLanguagesKey)
        }
    }

    private var appLanguageOverride: Any? {
        guard let domain else { return nil }
        return defaults.persistentDomain(forName: domain)?[Self.appleLanguagesKey]
    }

    var systemLanguages: [String] {
        // Read the global domain directly so our own AppleLanguages cannot shadow it.
        defaults.persistentDomain(forName: UserDefaults.globalDomain)?[Self.appleLanguagesKey] as? [String] ?? []
    }

    func removeInvalidOverride() {
        if appLanguageOverride != nil, selection == nil {
            selection = nil
        }
    }

    static func resolve(
        selection: InterfaceLanguage?,
        systemLanguages: [String]
    ) -> (language: InterfaceLanguage, locale: Locale) {
        if let selection {
            return (selection, Locale(identifier: selection.rawValue))
        }
        return firstSupportedLanguage(in: systemLanguages) ?? (.english, Locale(identifier: InterfaceLanguage.english.rawValue))
    }

    private static func firstSupportedLanguage(in identifiers: [String]) -> (language: InterfaceLanguage, locale: Locale)? {
        for identifier in identifiers {
            let locale = Locale(identifier: identifier)
            if let code = locale.language.languageCode?.identifier,
               let language = InterfaceLanguage(rawValue: code) {
                return (language, locale)
            }
        }
        return nil
    }
}
