import Foundation
import Testing

/// Translated catalogues that must stay in lockstep with en.lproj. Mirrors
/// meow-android's `values-*` resource set (zh-CN maps to zh-Hans on iOS).
private let translations = ["ar", "fa", "my", "ru", "tr", "vi", "zh-Hans"]

/// Guards against silent key drift between `en.lproj/Localizable.strings`
/// (developmentRegion) and every translated catalogue. Each translation
/// must share en's key set — if a SwiftUI view introduces `Text("foo.bar")`
/// but only `en.lproj` carries the value, a device in that locale renders
/// the raw key string. The reverse (a translation with an extra key) is
/// dead weight that won't survive a translator pass.
///
/// Test runs against the host app bundle, so `Bundle.main` here is the
/// `meow-ios.app` (unit-test target is hosted by the app target).
@Suite("Localizable.strings parity (en ⇄ translations)")
struct LocalizableParityTests {
    @Test
    func `app bundle ships every translation`() {
        let shipped = Set(Bundle.main.localizations)
        let missing = translations.filter { !shipped.contains($0) }
        #expect(missing.isEmpty, "Localizations missing from the app bundle: \(missing)")
    }

    @Test(arguments: translations)
    func `translation shares the en key set`(localization: String) throws {
        let en = try loadStrings(localization: "en")
        let translated = try loadStrings(localization: localization)

        let enKeys = Set(en.keys)
        let translatedKeys = Set(translated.keys)
        let missing = enKeys.subtracting(translatedKeys).sorted()
        let extra = translatedKeys.subtracting(enKeys).sorted()
        #expect(
            missing.isEmpty,
            "\(localization) is missing keys present in en.lproj: \(missing)",
        )
        #expect(
            extra.isEmpty,
            "\(localization) has keys absent from en.lproj (orphans): \(extra)",
        )
    }

    @Test(arguments: translations)
    func `every translated value is non-empty`(localization: String) throws {
        let translated = try loadStrings(localization: localization)
        let empties = translated.filter(\.value.isEmpty).keys.sorted()
        #expect(empties.isEmpty, "\(localization) has empty values for keys: \(empties)")
    }

    @Test(arguments: translations)
    func `printf format specifiers match en`(localization: String) throws {
        // If en has "Total %@" and a translation turns that into
        // "合计 %lld" the runtime crashes when SwiftUI feeds it a string
        // argument. Compare the multiset of conversion specifiers (%@,
        // %lld, %d, %f, %1$@, …) per key.
        let en = try loadStrings(localization: "en")
        let translated = try loadStrings(localization: localization)
        for (key, enValue) in en {
            guard let translatedValue = translated[key] else { continue } // covered by key-set test
            let enSpecs = formatSpecifiers(in: enValue).sorted()
            let translatedSpecs = formatSpecifiers(in: translatedValue).sorted()
            #expect(
                enSpecs == translatedSpecs,
                "Format specifier mismatch for '\(key)': en=\(enSpecs) \(localization)=\(translatedSpecs)",
            )
        }
    }

    // MARK: - Helpers

    private func loadStrings(localization: String) throws -> [String: String] {
        // `Bundle.main` is the host app's bundle when run from a unit-test
        // target hosted by an iOS app target.
        guard let path = Bundle.main.path(
            forResource: "Localizable",
            ofType: "strings",
            inDirectory: nil,
            forLocalization: localization,
        ) else {
            Issue.record("Could not locate Localizable.strings for '\(localization)' in host bundle")
            return [:]
        }
        let dict = NSDictionary(contentsOfFile: path) as? [String: String]
        return dict ?? [:]
    }

    /// Extract printf-style conversion specifiers from a format string.
    /// Returns the literal `%@`, `%lld`, `%d`, `%f`, `%1$@`, … tokens —
    /// `%%` (literal percent) is skipped. Conservative regex that accepts
    /// the subset Foundation actually emits in Localizable.strings.
    private func formatSpecifiers(in value: String) -> [String] {
        // %% must not be counted, so consume it first and ignore.
        // Then match %[positional$][length-flag]conversion.
        let pattern = #"%(?:[0-9]+\$)?(?:[-+#0 ]?[0-9]*)?(?:l{1,2}|h{1,2}|q|z|j|t)?[@diouxXeEfgGsScCp%]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = value as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: value, range: range)
            .map { ns.substring(with: $0.range) }
            .filter { $0 != "%%" }
    }
}
