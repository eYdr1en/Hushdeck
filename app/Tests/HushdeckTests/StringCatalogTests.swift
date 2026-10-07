import Foundation
import Testing

/// Checks Sources/Hushdeck/Resources/Localizable.xcstrings: every language covers every
/// string, placeholders match, nothing is stale, and every string the compiler
/// extracted from the sources is in the catalog.
@Suite("String Catalog")
struct StringCatalogTests {
    static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let catalogURL = appRoot.appendingPathComponent("Sources/Hushdeck/Resources/Localizable.xcstrings")

    struct Catalog: Decodable {
        struct Entry: Decodable {
            var extractionState: String?
            var shouldTranslate: Bool?
            var localizations: [String: Localization]?
        }
        struct Localization: Decodable {
            struct Unit: Decodable {
                var state: String
                var value: String
            }
            var stringUnit: Unit?
            var variations: [String: [String: Localization]]?

            /// Every string value, including plural/device variations.
            var allUnits: [Unit] {
                var units = stringUnit.map { [$0] } ?? []
                for group in (variations ?? [:]).values {
                    for variation in group.values { units += variation.allUnits }
                }
                return units
            }
        }
        var sourceLanguage: String
        var strings: [String: Entry]
    }

    static func loadCatalog() throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
    }

    /// Format specifiers without positions, sorted: "%1$@ has %2$lld" -> ["%@", "%lld"].
    static func placeholders(_ string: String) -> [String] {
        let pattern = /%(?:\d+\$)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSaA]/
        return string.matches(of: pattern).map { match in
            String(match.output).replacing(/\d+\$/, with: "")
        }.sorted()
    }

    @Test func sourceLanguageIsEnglish() throws {
        #expect(try Self.loadCatalog().sourceLanguage == "en")
    }

    @Test func shipsGerman() throws {
        let catalog = try Self.loadCatalog()
        let languages = Set(catalog.strings.values.flatMap { ($0.localizations ?? [:]).keys })
        #expect(languages.contains("de"))
    }

    @Test func everyLanguageTranslatesEveryString() throws {
        let catalog = try Self.loadCatalog()
        let translatable = catalog.strings.filter { $0.value.shouldTranslate != false }
        let languages = Set(translatable.values.flatMap { ($0.localizations ?? [:]).keys })
            .subtracting([catalog.sourceLanguage])
        #expect(!languages.isEmpty)
        for language in languages.sorted() {
            for (key, entry) in translatable.sorted(by: { $0.key < $1.key }) {
                let units = entry.localizations?[language]?.allUnits ?? []
                #expect(!units.isEmpty, "\(language): missing translation for \"\(key)\"")
                for unit in units {
                    #expect(unit.state == "translated", "\(language): \"\(key)\" is \(unit.state)")
                    #expect(!unit.value.isEmpty, "\(language): empty translation for \"\(key)\"")
                }
            }
        }
    }

    @Test func placeholdersMatchTheSource() throws {
        let catalog = try Self.loadCatalog()
        for (key, entry) in catalog.strings.sorted(by: { $0.key < $1.key }) {
            let expected = Self.placeholders(key)
            for (language, localization) in entry.localizations ?? [:] {
                for unit in localization.allUnits where localization.variations == nil {
                    #expect(Self.placeholders(unit.value) == expected,
                            "\(language): \"\(unit.value)\" doesn't have the placeholders of \"\(key)\"")
                }
            }
        }
    }

    @Test func noStaleStrings() throws {
        let stale = try Self.loadCatalog().strings.filter { $0.value.extractionState == "stale" }.keys.sorted()
        #expect(stale.isEmpty, "Unused strings in the catalog (run scripts/sync-strings.sh): \(stale)")
    }

    /// Uses the `.stringsdata` files the Swift compiler writes while building the app
    /// target, so it sees exactly what SwiftUI and `String(localized:)` will look up.
    @Test(.enabled(if: !CompilerStrings.keys().isEmpty, "no .stringsdata in .build (build system didn't emit them)"))
    func everyStringInTheSourcesIsInTheCatalog() throws {
        let catalogKeys = Set(try Self.loadCatalog().strings.keys)
        let missing = CompilerStrings.keys().subtracting(catalogKeys).sorted()
        #expect(missing.isEmpty, "Strings missing from Localizable.xcstrings (run scripts/sync-strings.sh): \(missing)")
    }
}

/// Reads the newest `.stringsdata` per source file of the Hushdeck target from `.build`.
enum CompilerStrings {
    struct StringsData: Decodable {
        struct Item: Decodable { var key: String }
        var source: String
        var tables: [String: [Item]]
    }

    static func keys() -> Set<String> {
        let build = StringCatalogTests.appRoot.appendingPathComponent(".build")
        let sources = StringCatalogTests.appRoot.appendingPathComponent("Sources/Hushdeck").standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: build, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        var newest: [String: (date: Date, keys: [String])] = [:]
        for case let url as URL in enumerator where url.pathExtension == "stringsdata" {
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(StringsData.self, from: data) else { continue }
            let source = URL(fileURLWithPath: file.source).resolvingSymlinksInPath().path
            guard source.hasPrefix(sources + "/"), FileManager.default.fileExists(atPath: source) else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let existing = newest[source], existing.date >= date { continue }
            newest[source] = (date, file.tables["Localizable"]?.map(\.key) ?? [])
        }
        return Set(newest.values.flatMap(\.keys))
    }
}
