import Foundation

/// ISO-3166 alpha-2 → flag emoji, by regional-indicator arithmetic.
///
/// The alpha-2 comes from the CLI (`public.country_iso`), so nothing here
/// has to ship or maintain a country table — the mapping is pure Unicode:
/// U+1F1E6 REGIONAL INDICATOR SYMBOL LETTER A is offset by the letter's
/// distance from 'A', and a pair of them renders as a flag.
enum Flag {
    static func emoji(forISOCode code: String?) -> String? {
        guard let code else { return nil }
        let letters = code.trimmingCharacters(in: .whitespaces).uppercased()
        // Exactly two ASCII letters. A country *name* ("Brazil") arriving
        // here by mistake would otherwise render as a run of unrelated
        // symbols rather than as nothing.
        guard letters.count == 2,
              letters.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }

        let base: UInt32 = 0x1F1E6
        var scalars = String.UnicodeScalarView()
        for char in letters.unicodeScalars {
            guard let scalar = Unicode.Scalar(base + char.value - 65) else { return nil }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
