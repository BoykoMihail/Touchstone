import Foundation
import Touchstone

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A backend for any server that speaks the OpenAI chat-completions dialect.
///
/// That is one implementation for OpenAI, Ollama, LM Studio, llama.cpp's server
/// and Groq — they differ by a base URL and whether a key is needed. The point
/// of shipping it second is not breadth: it is that a protocol with one
/// implementation is a guess, and `LanguageModel` had to meet something that
/// wasn't designed alongside it.
///
///     let ai = Assayer(model: OpenAICompatibleModel(configuration: .ollama(model: "llama3.2")))
///
/// Everything except the two `URLSession` calls in this file is pure and covered
/// by tests: building the request, reading an SSE line, turning a status code
/// into an error a caller can branch on.
public struct OpenAICompatibleModel: LanguageModel, @unchecked Sendable {

    // @unchecked because `URLSession` carries no Sendable guarantee on every
    // platform this builds for. It is only ever read here, never mutated.

    public struct Configuration: Sendable {

        /// The API root, including any version path: `https://api.openai.com/v1`,
        /// `http://localhost:11434/v1`. `chat/completions` is appended to it.
        public var baseURL: URL

        /// The model name as that server spells it — `gpt-4o-mini`, `llama3.2`.
        public var model: String

        /// `nil` for a local server that doesn't want one. When nil, no
        /// `Authorization` header is sent at all, rather than an empty one.
        public var apiKey: String?

        /// Anything a particular host insists on: an org id, a project header.
        public var extraHeaders: [String: String]

        public init(
            baseURL: URL,
            model: String,
            apiKey: String? = nil,
            extraHeaders: [String: String] = [:]
        ) {
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
            self.extraHeaders = extraHeaders
        }

        /// Ollama on the default local port. No key, no account, no network —
        /// which is what makes it the honest way to try this library out.
        public static func ollama(
            model: String,
            host: URL = URL(string: "http://localhost:11434/v1")!
        ) -> Configuration {
            Configuration(baseURL: host, model: model)
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    // MARK: - LanguageModel

    public func respond(to prompt: String, options: ModelOptions) async throws -> String {
        try Task.checkCancellation()
        let request = try makeRequest(prompt: prompt, options: options, streaming: false)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw OpenAICompatibleError.transport("\(error)")
        }

        try Self.checkStatus(of: response, body: data)

        guard let decoded = try? JSONDecoder().decode(ChatCompletionsResponse.self, from: data) else {
            throw OpenAICompatibleError.malformedResponse(OpenAICompatibleError.shortText(data))
        }
        guard let content = decoded.firstContent else {
            throw OpenAICompatibleError.malformedResponse("the response carried no message content")
        }
        return content
    }

    public func stream(_ prompt: String, options: ModelOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // Same cancellation story as the on-device backend: the work is a
            // child task of the stream, so dropping the consumer stops the
            // generation. No handle to keep, nothing to tear down.
            let task = Task {
                do {
                    let request = try makeRequest(prompt: prompt, options: options, streaming: true)
                    try await consume(request, into: continuation)
                    continuation.finish()
                } catch let error as CancellationError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request

    /// Internal rather than private so the tests can look at what goes on the
    /// wire without a server: the URL, the headers, the encoded body.
    func makeRequest(
        prompt: String,
        options: ModelOptions,
        streaming: Bool
    ) throws -> URLRequest {
        let url = configuration.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if streaming {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        // No key means no header. An empty bearer token reads as a
        // configuration bug on the server side and comes back as a 401 that
        // sends you looking in the wrong place.
        if let key = configuration.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in configuration.extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let body = ChatCompletionsRequest(
            model: configuration.model,
            prompt: prompt,
            temperature: options.temperature,
            maxTokens: options.maximumTokens,
            stream: streaming
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Turns a non-2xx answer into a typed error. Shared by both calls so the
    /// streaming and non-streaming paths can't drift apart.
    static func checkStatus(of response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.malformedResponse("the response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAICompatibleError.from(
                status: http.statusCode,
                body: body,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
    }

    // MARK: - Streaming transport

    #if canImport(FoundationNetworking)

    /// Non-Apple Foundation ships no `URLSession.bytes(for:)`, so there is no
    /// byte stream to read. Failing with a named case beats failing with a
    /// missing symbol at link time, and keeps this target building on Linux CI —
    /// which is what proves the rest of it has no Apple dependency.
    private func consume(
        _ request: URLRequest,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        throw OpenAICompatibleError.streamingUnavailable
    }

    #else

    private func consume(
        _ request: URLRequest,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw OpenAICompatibleError.transport("\(error)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.malformedResponse("the response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The error body arrives through the same byte stream, so it has to
            // be drained before it can be read.
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw OpenAICompatibleError.from(
                status: http.statusCode,
                body: body,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
            )
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = ServerSentEvent.from(line: line) else { continue }

            switch event {
            case .done:
                return
            case .data(let payload):
                // A chunk this version doesn't understand is skipped rather
                // than fatal: servers add fields, and a stream that dies on an
                // unknown key is a stream that breaks on someone else's release.
                guard let chunk = try? JSONDecoder().decode(
                    ChatCompletionsChunk.self,
                    from: Data(payload.utf8)
                ) else { continue }

                if let delta = chunk.deltaContent, !delta.isEmpty {
                    continuation.yield(delta)
                }
            }
        }
    }

    #endif
}
