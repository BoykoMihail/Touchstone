import Foundation

/// A `Decimal` that decodes from either a JSON number or a numeric string,
/// exactly, and from nothing else.
///
/// Foundation already decodes `Decimal` from a JSON number without losing
/// precision — `8.40` really does come back as `8.4`, not `8.400000000000000355`.
/// So this type is not here to fix the decoder. It is here because the *model*
/// is inconsistent: asked for an amount, it writes `8.40` one time and `"8.40"`
/// the next, and a plain `Decimal` field fails on the second one.
///
/// Accepting both costs ten lines and saves a round-trip to the model every time
/// it picks the other form. What it still refuses is anything that isn't a
/// number — `"about 8.40"`, `"$8.40"`, `"eight forty"` — because guessing what
/// those meant is how a balance ends up wrong. Those become a repairable error
/// instead: the model is told what was wrong and asked again.
///
/// There is deliberately no currency, no rounding and no formatting here. Those
/// belong to your domain, not to a library about model output.
public struct LenientDecimal: Sendable, Hashable, Codable, CustomStringConvertible {

    public let value: Decimal

    public init(_ value: Decimal) {
        self.value = value
    }

    /// Parses a decimal string. Returns `nil` rather than zero when the text
    /// isn't a number: a silent zero in a numeric field is a lie with a clean
    /// conscience.
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let parsed = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")),
              // Decimal(string:) parses a prefix, so "8.40 EUR" would sneak
              // through. Round-tripping catches that.
              trimmed == NSDecimalNumber(decimal: parsed).stringValue
                  || trimmed == "+\(NSDecimalNumber(decimal: parsed).stringValue)"
                  || Self.isSameNumberText(trimmed, parsed)
        else { return nil }
        self.value = parsed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let number = try? container.decode(Decimal.self) {
            self.value = number
            return
        }

        let text = try container.decode(String.self)
        guard let parsed = LenientDecimal(string: text) else {
            throw AssayError.notANumber(text)
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public var description: String {
        NSDecimalNumber(decimal: value).stringValue
    }

    /// True when the text differs from the canonical form only in ways that
    /// don't change the number: trailing zeros, a leading zero, a plus sign.
    private static func isSameNumberText(_ text: String, _ parsed: Decimal) -> Bool {
        let allowed = Set("0123456789.+-")
        guard text.allSatisfy({ allowed.contains($0) }) else { return false }
        guard let reparsed = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            return false
        }
        return reparsed == parsed
    }
}
