import Foundation

/// What can go wrong talking to an OpenAI-compatible server, split by what the
/// caller can do about it.
///
/// The cases deliberately mirror `FoundationModelError` from the on-device
/// backend. That symmetry is the point of having two backends at all: if a
/// caller has to write different error handling per backend, the abstraction
/// was never real.
public enum OpenAICompatibleError: Error, Sendable, Equatable, CustomStringConvertible {

    /// The key is missing, wrong, or lacks access to this model. Retrying is pointless.
    case unauthorized(String)

    /// Too many requests. `retryAfter` is the server's advice, in seconds, when it gave one.
    case rateLimited(retryAfter: TimeInterval?)

    /// Prompt plus history exceeded the model's context window. Send less.
    case promptTooLong(String)

    /// A content filter rejected the prompt or the answer. Re-asking the same
    /// prompt won't help — which is why this is not an `AssayError` and never
    /// feeds the repair loop.
    case refused(String)

    /// The server answered, but not with anything usable.
    case malformedResponse(String)

    /// Any other non-2xx answer, with the status and whatever the body said.
    case serverError(status: Int, message: String)

    /// The request never completed: no network, DNS, TLS, a timeout.
    case transport(String)

    /// Streaming needs an API this platform's Foundation doesn't ship.
    case streamingUnavailable

    public var description: String {
        switch self {
        case .unauthorized(let detail): return "unauthorized: \(detail)"
        case .rateLimited(let after):
            return after.map { "rate limited, retry after \($0)s" } ?? "rate limited"
        case .promptTooLong(let detail): return "prompt too long: \(detail)"
        case .refused(let detail): return "the server refused: \(detail)"
        case .malformedResponse(let detail): return "malformed response: \(detail)"
        case .serverError(let status, let message): return "server error \(status): \(message)"
        case .transport(let detail): return "transport failure: \(detail)"
        case .streamingUnavailable: return "streaming is not available on this platform"
        }
    }
}

// MARK: - Mapping

extension OpenAICompatibleError {

    /// Turns an HTTP status and response body into a case a caller can branch on.
    ///
    /// Pure on purpose: this is the part most likely to be wrong, and the part
    /// that is hardest to exercise against a live server. Keeping it a function
    /// of two values means the tests can cover every branch in milliseconds.
    public static func from(
        status: Int,
        body: Data,
        retryAfterHeader: String? = nil
    ) -> OpenAICompatibleError {
        let message = apiMessage(in: body) ?? shortText(body)

        switch status {
        case 401, 403:
            return .unauthorized(message)
        case 429:
            return .rateLimited(retryAfter: retryAfterHeader.flatMap(TimeInterval.init))
        case 400:
            // Servers disagree on the code but agree on the words. Matching on
            // the message is unlovely and still beats telling the caller
            // "bad request" when the fix is "send fewer tokens".
            let lowered = message.lowercased()
            if lowered.contains("context length")
                || lowered.contains("context_length")
                || lowered.contains("too many tokens")
                || lowered.contains("maximum context") {
                return .promptTooLong(message)
            }
            if lowered.contains("content filter")
                || lowered.contains("content_filter")
                || lowered.contains("content policy")
                || lowered.contains("safety") {
                return .refused(message)
            }
            return .serverError(status: status, message: message)
        default:
            return .serverError(status: status, message: message)
        }
    }

    /// Pulls `error.message` out of the standard error envelope, if it's there.
    static func apiMessage(in body: Data) -> String? {
        struct Envelope: Decodable {
            struct APIError: Decodable { let message: String }
            let error: APIError
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body) else {
            return nil
        }
        return envelope.error.message
    }

    /// A body that isn't the expected envelope still tells the reader something —
    /// but a wall of HTML in an error message helps nobody, so it gets clipped.
    static func shortText(_ body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "empty response body" }
        return text.count <= 200 ? text : String(text.prefix(200)) + "…"
    }
}
