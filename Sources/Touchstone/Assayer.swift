import Foundation

/// Entry point. Wraps a `LanguageModel` and adds typed output, bounded repair
/// and streaming that cancels with its task.
///
/// An assayer is the person who tests whether metal is what it claims to be.
/// Named that way rather than `Touchstone` so the type never collides with its
/// own module — `Touchstone.Something` should always mean the module.
public struct Assayer: Sendable {

    private let model: any LanguageModel
    private let options: ModelOptions
    private let maximumRepairs: Int

    /// - Parameters:
    ///   - model: the backend. Swap in `FakeModel` from `TouchstoneTesting` in tests.
    ///   - options: defaults applied when a call doesn't override them.
    ///   - maximumRepairs: how many times a malformed answer is re-asked before
    ///     giving up. Zero means one attempt and no repair.
    public init(
        model: any LanguageModel,
        options: ModelOptions = .structured,
        maximumRepairs: Int = 2
    ) {
        self.model = model
        self.options = options
        self.maximumRepairs = maximumRepairs
    }

    // MARK: - Typed output

    /// Asks for a value of `type` and returns it, or throws.
    ///
    /// Never returns a partially populated value: either the response decoded
    /// cleanly or you get an `AssayError`.
    public func value<T: Assayable>(
        _ type: T.Type,
        from prompt: String,
        options overrides: ModelOptions? = nil
    ) async throws -> T {
        let options = overrides ?? self.options
        var attempt = 0
        var lastReason = ""
        var conversation = Self.instructedPrompt(prompt, schema: T.jsonSchema)

        while attempt <= maximumRepairs {
            try Task.checkCancellation()

            let response = try await model.respond(to: conversation, options: options)

            do {
                return try Self.decode(T.self, from: response)
            } catch let error as AssayError {
                lastReason = Self.describe(error)
                attempt += 1
                conversation = Self.repairPrompt(
                    original: prompt,
                    schema: T.jsonSchema,
                    badResponse: response,
                    reason: lastReason
                )
            }
        }

        throw AssayError.repairsExhausted(attempts: attempt, lastReason: lastReason)
    }

    // MARK: - Streaming

    /// Streams chunks of text. Cancelling the consuming task stops generation:
    /// there is no handle to keep and nothing to remember to tear down.
    public func stream(
        _ prompt: String,
        options overrides: ModelOptions? = nil
    ) -> AsyncThrowingStream<String, Error> {
        model.stream(prompt, options: overrides ?? options)
    }

    // MARK: - Prompting

    static func instructedPrompt(_ prompt: String, schema: String) -> String {
        """
        \(prompt)

        Reply with JSON only. No prose, no code fences, no explanation.
        The JSON must match this shape:
        \(schema)
        Decimal amounts must be strings, for example "8.40".
        """
    }

    static func repairPrompt(
        original: String,
        schema: String,
        badResponse: String,
        reason: String
    ) -> String {
        """
        \(original)

        Your previous reply could not be used. Reason: \(reason)
        Previous reply:
        \(badResponse)

        Reply again with JSON only, matching this shape exactly:
        \(schema)
        Decimal amounts must be strings, for example "8.40".
        """
    }

    // MARK: - Decoding

    static func decode<T: Assayable>(_ type: T.Type, from response: String) throws -> T {
        guard let json = extractJSON(from: response) else {
            throw AssayError.noJSONFound(response: response)
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch let error as AssayError {
            throw error
        } catch {
            throw AssayError.decodingFailed(reason: "\(error)", response: response)
        }
    }

    /// Pulls the first balanced JSON object out of a response, because models
    /// wrap JSON in fences and pleasantries no matter how firmly you ask them not to.
    static func extractJSON(from response: String) -> String? {
        guard let start = response.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = start
        while index < response.endIndex {
            let character = response[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(response[start...index])
                }
            }
            index = response.index(after: index)
        }
        return nil
    }

    static func describe(_ error: AssayError) -> String {
        switch error {
        case .noJSONFound:
            return "the reply contained no JSON object"
        case .decodingFailed(let reason, _):
            return reason
        case .notANumber(let text):
            return "\"\(text)\" is not a decimal number"
        case .moneyWasNotAString:
            return "a decimal amount was sent as a number; send it as a string"
        case .repairsExhausted(_, let lastReason):
            return lastReason
        }
    }
}
