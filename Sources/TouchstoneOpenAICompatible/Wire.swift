import Foundation

// The wire format, kept in one place and deliberately small: this library
// sends one user message and reads one answer. Anything richer belongs to the
// caller's own client, not to a library about making model output typed.

struct ChatCompletionsRequest: Encodable, Equatable {

    struct Message: Encodable, Equatable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double?
    /// `max_tokens` rather than the newer `max_completion_tokens`: every
    /// compatible server still accepts the old spelling, and several of the
    /// local ones accept nothing else.
    let maxTokens: Int?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
    }

    init(model: String, prompt: String, temperature: Double?, maxTokens: Int?, stream: Bool) {
        self.model = model
        self.messages = [Message(role: "user", content: prompt)]
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
    }
}

struct ChatCompletionsResponse: Decodable {

    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
    }

    let choices: [Choice]

    /// The first choice's text, or `nil` when the server sent a shape we can't use.
    var firstContent: String? {
        choices.first?.message?.content
    }
}

struct ChatCompletionsChunk: Decodable {

    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
    }

    let choices: [Choice]

    /// The delta carried by this chunk. Empty deltas are normal — the first
    /// chunk usually carries only the role — so an absent value is not an error.
    var deltaContent: String? {
        choices.first?.delta?.content
    }
}
