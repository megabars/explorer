import Foundation
import Testing
@testable import Explorer

struct LocalizationTests {
    @Test
    func systemLanguageUsesTheFirstSupportedPreferenceAndKeepsItsRegion() {
        let resolved = LanguagePreferences.resolve(selection: nil, systemLanguages: ["fr-CA", "es-MX", "ru-RU"])
        #expect(resolved.language == .spanish)
        #expect(resolved.locale.region?.identifier == "MX")
        #expect(LanguagePreferences.resolve(selection: nil, systemLanguages: ["en-GB", "ru-RU"]).language == .english)
        #expect(LanguagePreferences.resolve(selection: nil, systemLanguages: ["ru-RU", "en-GB"]).language == .russian)
    }

    @Test
    func unsupportedSystemLanguagesFallBackToEnglish() {
        #expect(LanguagePreferences.resolve(selection: nil, systemLanguages: ["", "ja-JP"]).language == .english)
        #expect(LanguagePreferences.resolve(selection: nil, systemLanguages: []).language == .english)
    }

    @Test
    func languageChoicePersistsAndClearsOnlyItsAppDomainOverride() throws {
        let domain = "com.explorer.localization-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = LanguagePreferences(defaults: defaults, domain: domain)
        let originalSystemLanguages = preferences.systemLanguages
        #expect(preferences.selection == nil)

        for language in InterfaceLanguage.allCases {
            preferences.selection = language
            let nextLaunchDefaults = try #require(UserDefaults(suiteName: domain))
            let nextLaunch = LanguagePreferences(defaults: nextLaunchDefaults, domain: domain)
            #expect(nextLaunch.selection == language)
            #expect(nextLaunchDefaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String] == [language.rawValue])
            #expect(nextLaunch.systemLanguages == originalSystemLanguages)
            #expect(LanguagePreferences.resolve(selection: nextLaunch.selection, systemLanguages: ["fr"]).language == language)
        }

        preferences.selection = nil
        #expect(preferences.selection == nil)
        #expect(defaults.persistentDomain(forName: domain)?["AppleLanguages"] == nil)
        #expect(preferences.systemLanguages == originalSystemLanguages)
    }

    @Test
    func invalidAppLanguageIsClearedAndResolutionReturnsToSystem() throws {
        let domain = "com.explorer.localization-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = LanguagePreferences(defaults: defaults, domain: domain)
        let originalSystemLanguages = preferences.systemLanguages
        defaults.set("keep", forKey: "unrelatedPreference")
        for invalidOverride: Any in ["es", ["invalid-language"], [String]()] {
            defaults.set(invalidOverride, forKey: LanguagePreferences.appleLanguagesKey)
            #expect(preferences.selection == nil)
            preferences.removeInvalidOverride()
            #expect(defaults.persistentDomain(forName: domain)?[LanguagePreferences.appleLanguagesKey] == nil)
        }
        #expect(defaults.string(forKey: "unrelatedPreference") == "keep")
        #expect(preferences.systemLanguages == originalSystemLanguages)
        #expect(LanguagePreferences.resolve(selection: preferences.selection, systemLanguages: ["ru-RU"]).language == .russian)
    }

    @Test(arguments: [
        (InterfaceLanguage.english, "New Folder", "2 of 5 selected"),
        (.russian, "Новая папка", "Выбрано 2 из 5"),
        (.spanish, "Nueva carpeta", "2 de 5 seleccionados")
    ])
    func translationsUseTheChosenLanguage(language: InterfaceLanguage, folderName: String, selection: String) {
        let strings = LocalizedStrings(language: language, locale: Locale(identifier: language.rawValue))
        #expect(strings.text("New Folder") == folderName)
        #expect(strings.format("%d of %d selected", arguments: [2, 5]) == selection)
        #expect(strings.text("Untranslated English text") == "Untranslated English text")
    }

    @Test(arguments: [
        (InterfaceLanguage.english,
         ["0 items", "1 item", "2 items", "5 items", "11 items", "21 items", "22 items"],
         ["0 results", "1 result", "2 results", "5 results", "11 results", "21 results", "22 results"]),
        (.russian,
         ["0 объектов", "1 объект", "2 объекта", "5 объектов", "11 объектов", "21 объект", "22 объекта"],
         ["0 результатов", "1 результат", "2 результата", "5 результатов", "11 результатов", "21 результат", "22 результата"]),
        (.spanish,
         ["0 elementos", "1 elemento", "2 elementos", "5 elementos", "11 elementos", "21 elementos", "22 elementos"],
         ["0 resultados", "1 resultado", "2 resultados", "5 resultados", "11 resultados", "21 resultados", "22 resultados"])
    ])
    func countsUseTheCorrectPluralForms(language: InterfaceLanguage, items: [String], results: [String]) {
        let strings = LocalizedStrings(language: language, locale: Locale(identifier: language.rawValue))
        let counts = [0, 1, 2, 5, 11, 21, 22]
        #expect(counts.map { strings.plural("items.count", count: $0) } == items)
        #expect(counts.map { strings.plural("results.count", count: $0) } == results)
    }
}
