import Foundation

/// Anything that can turn a prompt into text.
///
/// This is the only thing Touchstone needs from a model, which is why it has two
/// methods and no associated types: an on-device model, a cloud API and a fake
/// are interchangeable everywhere, tests included.
public protocol LanguageModel: Sendable {

    /// One-shot completion.
    func respond(to prompt: String, options: ModelOptions) async throws -> String

    /// Incremental completion. Each element is a new chunk, not the accumulated text.
    ///
    /// Cancelling the consuming task must stop generation: implementations run
    /// their work inside the stream's task so that structured concurrency does
    /// this for free, rather than asking callers to hold a handle.
    func stream(_ prompt: String, options: ModelOptions) -> AsyncThrowingStream<String, Error>
}

/// Knobs that every backend understands. Anything model-specific belongs to the
/// backend's own initialiser, not here — this type stays small on purpose.
///
/// Named `ModelOptions` rather than `GenerationOptions` deliberately: Apple's
/// `FoundationModels` framework already owns the latter, and a backend file that
/// imports both modules would have to disambiguate every mention of it.
public struct ModelOptions: Sendable, Equatable {

    /// 0 = as deterministic as the backend can manage. Structured output wants low values.
    public var temperature: Double

    /// Upper bound on generated tokens, when the backend supports it.
    public var maximumTokens: Int?

    public init(temperature: Double = 0.2, maximumTokens: Int? = nil) {
        self.temperature = temperature
        self.maximumTokens = maximumTokens
    }

    /// Sensible default for typed output: no creativity, no explicit cap.
    public static let structured = ModelOptions(temperature: 0.0)
}
