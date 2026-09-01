/// Encodes one untrusted value as a CSV field.
///
/// C0 controls that are not meaningful CSV whitespace are replaced before
/// export. Spreadsheet formula prefixes are neutralized after leading
/// whitespace and controls so an attacker cannot hide one behind characters
/// that an importer may discard.
public enum CSVFieldEncoder {
    public static func encode(_ raw: String) -> String {
        let normalized = String(
            raw.unicodeScalars.map { scalar -> Character in
                if scalar.value < 0x20,
                    scalar != "\t", scalar != "\n", scalar != "\r"
                {
                    return "\u{FFFD}"
                }
                return Character(scalar)
            })

        let firstSignificantScalar = raw.unicodeScalars.first { scalar in
            scalar.value >= 0x20 && !Character(scalar).isWhitespace
        }
        let formulaPrefix =
            firstSignificantScalar.map {
                $0 == "=" || $0 == "+" || $0 == "-" || $0 == "@"
            } ?? false
        let safe = formulaPrefix ? "'" + normalized : normalized

        if safe.contains(",") || safe.contains("\"") || safe.contains("\n")
            || safe.contains("\r")
        {
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return safe
    }
}
