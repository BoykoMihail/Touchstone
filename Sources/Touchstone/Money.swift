import Foundation

/// A decimal amount that never passes through a binary floating-point type.
///
/// `JSONDecoder` decodes `Decimal` by way of `Double`, which is exactly the bug
/// this library exists to prevent: `8.40` becomes `8.4000000000000004` and a
/// balance is off by a cent that nobody can explain. `Money` therefore decodes
/// from the *string* form and parses it with `Decimal(string:)`.
///
/// Schemas should ask the model for a string:
/// ```
/// { "amount": "string, decimal amount, e.g. \"8.40\"" }
/// ```
///
/// A value that isn't a parseable decimal is an error, not a zero. Silently
/// defaulting to zero in money code is how you lie to a user with a clear
/// conscience.
public struct Money: Sendable, Hashable, Codable, CustomStringConvertible {

    public let decimal: Decimal

    public init(_ decimal: Decimal) {
        self.decimal = decimal
    }

    /// Parses a decimal string. Returns `nil` rather than zero when the text
    /// isn't a number.
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        self.decimal = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Preferred: the model emitted a string, and no Double was involved.
        if let text = try? container.decode(String.self) {
            guard let money = Money(string: text) else {
                throw AssayError.notANumber(text)
            }
            self = money
            return
        }

        // Tolerated: an integer. Exact, so it is safe to accept.
        if let whole = try? container.decode(Int.self) {
            self = Money(Decimal(whole))
            return
        }

        // Refused: a JSON floating-point literal. It has already lost precision
        // by the time it reaches us, so accepting it would be theatre.
        throw AssayError.moneyWasNotAString
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        NSDecimalNumber(decimal: decimal).stringValue
    }
}
