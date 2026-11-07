import Foundation

enum L10n {
    private static let launch = {
        let preferences = LanguagePreferences()
        let selection = preferences.selection
        let resolved = LanguagePreferences.resolve(selection: selection, systemLanguages: preferences.systemLanguages)
        return (selection: selection, strings: LocalizedStrings(language: resolved.language, locale: resolved.locale))
    }()

    static var launchSelection: InterfaceLanguage? { launch.selection }
    static var locale: Locale { launch.strings.locale }

    static func text(_ key: String) -> String {
        launch.strings.text(key)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        launch.strings.format(key, arguments: arguments)
    }

    static func plural(_ key: String, count: Int) -> String {
        launch.strings.plural(key, count: count)
    }
}

struct LocalizedStrings {
    private static let resources =
        Bundle.main.url(forResource: "Explorer_Explorer", withExtension: "bundle").flatMap(Bundle.init(url:))
        ?? Bundle.module

    let locale: Locale
    private let translations: Bundle?
    private let english: Bundle?

    init(language: InterfaceLanguage, locale: Locale) {
        self.locale = locale
        self.translations = Self.translationBundle(for: language)
        self.english = language == .english ? translations : Self.translationBundle(for: .english)
    }

    func text(_ key: String) -> String {
        let translated = translations?.localizedString(forKey: key, value: nil, table: nil)
        if let translated, translated != key {
            return translated
        }
        return english?.localizedString(forKey: key, value: nil, table: nil) ?? key
    }

    func format(_ key: String, arguments: [CVarArg]) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }

    func plural(_ key: String, count: Int) -> String {
        String(format: text(key), locale: locale, count)
    }

    private static func translationBundle(for language: InterfaceLanguage) -> Bundle? {
        resources.url(forResource: language.rawValue, withExtension: "lproj").flatMap(Bundle.init(url:))
    }
}
