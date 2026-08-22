import Foundation

/// A type the model can be asked to produce.
///
/// `jsonSchema` is prose, not a formal JSON Schema document — small models follow
/// a compact example far better than they follow a specification. Keep it short,
/// name the allowed values, and ask for money as a string.
public protocol Assayable: Decodable, Sendable {
    static var jsonSchema: String { get }
}

/// What went wrong between "the model answered" and "you have a value".
public enum AssayError: Error, Sendable, Equatable {

    /// The response wasn't JSON at all (usually prose wrapped around it).
    case noJSONFound(response: String)

    /// JSON parsed, but didn't match the type. Carries the decoder's complaint,
    /// which is also what gets fed back to the model on a repair attempt.
    case decodingFailed(reason: String, response: String)

    /// Ran out of repair attempts. Carries the last failure.
    case repairsExhausted(attempts: Int, lastReason: String)

    /// A money field held text that isn't a number.
    case notANumber(String)

    /// A money field arrived as a JSON float, which has already lost precision.
    case moneyWasNotAString
}
