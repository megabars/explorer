import Foundation
import Testing
@testable import Explorer

struct LocalizationCatalogTests {
    @Test func catalogsContainTheSameKeysAndCompatibleFormatArguments() throws {
        let english = try strings("en")
        let englishPlurals = try plurals("en")
        let formats = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?(?:ll|l)?[@diufgs]"#)
        func placeholders(_ value: String) -> [String] {
            formats.matches(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)).map {
                String(value[Range($0.range, in: value)!])
            }
        }

        for language in ["en", "ru", "es"] {
            let localized = try strings(language)
            #expect(Set(localized.keys) == Set(english.keys), "Missing text keys in \(language)")
            for (key, value) in localized {
                #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(placeholders(value) == placeholders(english[key] ?? ""),
                        "Format mismatch for \(language): \(key)")
            }

            let localizedPlurals = try plurals(language)
            #expect(Set(localizedPlurals.keys) == Set(englishPlurals.keys))
            for (key, record) in localizedPlurals {
                let count = try #require(record["count"] as? [String: String])
                #expect(count["NSStringFormatValueTypeKey"] == "d")
                #expect(count["NSStringFormatSpecTypeKey"] == "NSStringPluralRuleType")
                let requiredForms = language == "ru" ? ["one", "few", "many", "other"] : ["one", "other"]
                for form in requiredForms {
                    let value = try #require(count[form], "Missing \(form) for \(language): \(key)")
                    #expect(placeholders(value) == ["%d"])
                }
            }
        }
    }

    private func resource(_ language: String, fileExtension ext: String) throws -> Data {
        let directory = try #require(Bundle.module.url(forResource: language, withExtension: "lproj"))
        return try Data(contentsOf: directory.appendingPathComponent("Localizable.\(ext)"))
    }

    private func strings(_ language: String) throws -> [String: String] {
        let value = try PropertyListSerialization.propertyList(from: resource(language, fileExtension: "strings"), format: nil)
        return try #require(value as? [String: String])
    }

    private func plurals(_ language: String) throws -> [String: [String: Any]] {
        let value = try PropertyListSerialization.propertyList(from: resource(language, fileExtension: "stringsdict"), format: nil)
        return try #require(value as? [String: [String: Any]])
    }
}
