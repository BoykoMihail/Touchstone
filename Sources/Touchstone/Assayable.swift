import Foundation

/// A type the model can be asked to produce.
///
/// `jsonSchema` is prose, not a formal JSON Schema document — small models follow
/// a compact example far better than they follow a specification. Keep it short
/// and name the allowed values.
public protocol Assayable: Decodable, Sendable {
    static var jsonSchema: String { get }
}

/// What went wrong between "the model answered" and "you have a value".
///
/// Every case is something a caller can act on, and none of them is a value:
/// there is no path through this library that returns a default instead of an
/// error.
public enum AssayError: Error, Sendable, Equatable {

    /// The response wasn't JSON at all (usually prose wrapped around it).
    case noJSONFound(response: String)

    /// JSON parsed, but didn't match the type. Carries the decoder's complaint,
    /// which is also what gets fed back to the model on a repair attempt.
    case decodingFailed(reason: String, response: String)

    /// A numeric field held text that isn't a number — `"about 8.40"`, `"$8.40"`.
    case notANumber(String)

    /// Ran out of repair attempts. Carries the last failure.
    case repairsExhausted(attempts: Int, lastReason: String)
}
