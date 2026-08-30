import Foundation
import Testing
import Touchstone
@testable import TouchstoneOpenAICompatible

// Everything here runs without a server. That is the design claim of this
// backend: the only part that needs a network is the two URLSession calls, and
// every decision around them — what goes on the wire, what a line means, what a
// status code costs the caller — is a function of its inputs.

private func configuration(apiKey: String? = nil) -> OpenAICompatibleModel.Configuration {
    OpenAICompatibleModel.Configuration(
        baseURL: URL(string: "https://example.test/v1")!,
        model: "llama3.2",
        apiKey: apiKey
    )
}

private func json(of request: URLRequest) throws -> [String: Any] {
    let body = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
}

// MARK: - Request

@Test("Posts to chat/completions under the configured base URL")
func buildsTheEndpointURL() throws {
    let model = OpenAICompatibleModel(configuration: configuration())

    let request = try model.makeRequest(prompt: "hi", options: .structured, streaming: false)

    #expect(request.url?.absoluteString == "https://example.test/v1/chat/completions")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
}

@Test("Sends no Authorization header at all when there is no key")
func omitsAuthorizationWithoutAKey() throws {
    // A local server is the reason this backend exists. An empty bearer token
    // would come back as a 401 and send the reader looking in the wrong place.
    let model = OpenAICompatibleModel(configuration: configuration(apiKey: nil))

    let request = try model.makeRequest(prompt: "hi", options: .structured, streaming: false)

    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test("Sends a bearer token when a key is configured")
func sendsBearerToken() throws {
    let model = OpenAICompatibleModel(configuration: configuration(apiKey: "sk-test"))

    let request = try model.makeRequest(prompt: "hi", options: .structured, streaming: false)

    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
}

@Test("Carries the options onto the wire, and omits what wasn't set")
func encodesOptions() throws {
    let model = OpenAICompatibleModel(configuration: configuration())
    var options = ModelOptions.structured
    options.maximumTokens = 256

    let body = try json(of: model.makeRequest(prompt: "hi", options: options, streaming: false))

    #expect(body["model"] as? String == "llama3.2")
    #expect(body["temperature"] as? Double == 0.0)
    #expect(body["max_tokens"] as? Int == 256)
    #expect(body["stream"] as? Bool == false)

    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    #expect(messages[0]["role"] as? String == "user")
    #expect(messages[0]["content"] as? String == "hi")
}

@Test("Leaves max_tokens out entirely when the caller didn't ask for a limit")
func omitsAbsentTokenLimit() throws {
    // Sending null here is not the same as sending nothing: several local
    // servers reject an explicit null for this field.
    let model = OpenAICompatibleModel(configuration: configuration())

    let body = try json(of: model.makeRequest(prompt: "hi", options: .structured, streaming: false))

    #expect(body["max_tokens"] == nil)
}

@Test("Asks for an event stream only when streaming")
func setsStreamingHeaders() throws {
    let model = OpenAICompatibleModel(configuration: configuration())

    let plain = try model.makeRequest(prompt: "hi", options: .structured, streaming: false)
    let streamed = try model.makeRequest(prompt: "hi", options: .structured, streaming: true)

    #expect(plain.value(forHTTPHeaderField: "Accept") == nil)
    #expect(streamed.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    #expect(try json(of: streamed)["stream"] as? Bool == true)
}

// MARK: - Server-sent events

@Test("Reads a data line, the terminator, and ignores the noise between them")
func parsesEventLines() {
    #expect(ServerSentEvent.from(line: #"data: {"a":1}"#) == .data(#"{"a":1}"#))
    #expect(ServerSentEvent.from(line: "data:[DONE]") == .done)
    #expect(ServerSentEvent.from(line: "data: [DONE]") == .done)

    // Blank lines separate events; a `:` line is a proxy keep-alive; other
    // fields belong to parts of the SSE spec this dialect never uses.
    #expect(ServerSentEvent.from(line: "") == nil)
    #expect(ServerSentEvent.from(line: "   ") == nil)
    #expect(ServerSentEvent.from(line: ": keep-alive") == nil)
    #expect(ServerSentEvent.from(line: "event: message") == nil)
    #expect(ServerSentEvent.from(line: "id: 42") == nil)
}

@Test("Survives a carriage return the line splitter left behind")
func parsesCRLFLines() {
    // Miss this and the terminator never matches, so the stream hangs until
    // the connection closes instead of finishing.
    #expect(ServerSentEvent.from(line: "data: [DONE]\r") == .done)
    #expect(ServerSentEvent.from(line: #"data: {"a":1}"# + "\r") == .data(#"{"a":1}"#))
}

@Test("Pulls the delta out of a chunk, and tolerates one that carries none")
func decodesChunks() throws {
    let withText = #"{"choices":[{"delta":{"content":"Hel"}}]}"#
    let roleOnly = #"{"choices":[{"delta":{"role":"assistant"}}]}"#
    let empty = #"{"choices":[]}"#

    let decoder = JSONDecoder()
    #expect(try decoder.decode(ChatCompletionsChunk.self, from: Data(withText.utf8))
        .deltaContent == "Hel")
    // The first chunk usually announces the role and nothing else. Not an error.
    #expect(try decoder.decode(ChatCompletionsChunk.self, from: Data(roleOnly.utf8))
        .deltaContent == nil)
    #expect(try decoder.decode(ChatCompletionsChunk.self, from: Data(empty.utf8))
        .deltaContent == nil)
}

// MARK: - Errors

@Test("Maps a status code to something the caller can act on")
func mapsStatusCodes() {
    func body(_ message: String) -> Data {
        Data(#"{"error":{"message":"\#(message)"}}"#.utf8)
    }

    #expect(OpenAICompatibleError.from(status: 401, body: body("bad key"))
        == .unauthorized("bad key"))
    #expect(OpenAICompatibleError.from(status: 403, body: body("no access"))
        == .unauthorized("no access"))
    #expect(OpenAICompatibleError.from(status: 429, body: body("slow down"), retryAfterHeader: "30")
        == .rateLimited(retryAfter: 30))
    #expect(OpenAICompatibleError.from(status: 429, body: body("slow down"))
        == .rateLimited(retryAfter: nil))
    #expect(OpenAICompatibleError.from(status: 503, body: body("upstream is down"))
        == .serverError(status: 503, message: "upstream is down"))
}

@Test("Separates a prompt that is too long from a prompt that was refused")
func separatesTheTwoKindsOf400() {
    // Both arrive as 400 with a message, and the caller does opposite things:
    // one is «send less», the other is «this will never work, stop retrying».
    func body(_ message: String) -> Data {
        Data(#"{"error":{"message":"\#(message)"}}"#.utf8)
    }

    let tooLong = OpenAICompatibleError.from(
        status: 400,
        body: body("This model's maximum context length is 8192 tokens")
    )
    #expect(tooLong == .promptTooLong("This model's maximum context length is 8192 tokens"))

    let refused = OpenAICompatibleError.from(
        status: 400,
        body: body("Your request was rejected by our content filter")
    )
    #expect(refused == .refused("Your request was rejected by our content filter"))

    // Anything else at 400 stays generic rather than being guessed at.
    let other = OpenAICompatibleError.from(status: 400, body: body("unknown parameter: frequency"))
    #expect(other == .serverError(status: 400, message: "unknown parameter: frequency"))
}

@Test("Falls back to the raw body when it isn't the expected error envelope")
func readsBodiesThatArentTheEnvelope() {
    // A proxy in front of the model returns HTML, and «malformed JSON» is a
    // worse thing to log than the first line of the page.
    let html = Data("<html><body>502 Bad Gateway</body></html>".utf8)
    #expect(OpenAICompatibleError.from(status: 502, body: html)
        == .serverError(status: 502, message: "<html><body>502 Bad Gateway</body></html>"))

    #expect(OpenAICompatibleError.from(status: 500, body: Data())
        == .serverError(status: 500, message: "empty response body"))
}

@Test("Clips a very long body instead of pasting a page into an error")
func clipsLongBodies() {
    let long = Data(String(repeating: "x", count: 5_000).utf8)

    guard case .serverError(_, let message) = OpenAICompatibleError.from(status: 500, body: long)
    else {
        Issue.record("expected a server error")
        return
    }
    #expect(message.count == 201)      // 200 characters plus the ellipsis
    #expect(message.hasSuffix("…"))
}
