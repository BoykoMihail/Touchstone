#if canImport(Darwin)

import Foundation
import Testing
import Touchstone
@testable import TouchstoneOpenAICompatible

// The tests in OpenAICompatibleTests cover the pieces around the network. These
// cover the call itself — request goes out, status is read, body is decoded,
// failures come back as the right case — by giving URLSession a transport that
// answers from a script instead of a socket.
//
// Guarded to Apple platforms: custom URLProtocol registration is not dependable
// in non-Apple Foundation, and a flaky Linux job is worse than a job that
// honestly runs less.

/// A URLSession transport that answers from a stub instead of the network.
final class StubURLProtocol: URLProtocol {

    struct Stub {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
        var failure: Error?
    }

    nonisolated(unsafe) static var stub = Stub()
    /// The request as URLSession actually sent it — headers included.
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request

        if let failure = Self.stub.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: Self.stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

// The stub is shared state, so these run one at a time.
@Suite(.serialized)
struct OpenAICompatibleTransportTests {

    private func model(apiKey: String? = nil) -> OpenAICompatibleModel {
        OpenAICompatibleModel(
            configuration: .init(
                baseURL: URL(string: "https://example.test/v1")!,
                model: "llama3.2",
                apiKey: apiKey
            ),
            session: StubURLProtocol.session()
        )
    }

    private func reply(status: Int = 200, headers: [String: String] = [:], _ body: String) {
        StubURLProtocol.stub = .init(status: status, headers: headers, body: Data(body.utf8))
        StubURLProtocol.lastRequest = nil
    }

    @Test("Returns the assistant's text from a well-formed answer")
    func readsContent() async throws {
        reply(#"{"choices":[{"message":{"role":"assistant","content":"8.40"}}]}"#)

        let text = try await model().respond(to: "how much", options: .structured)

        #expect(text == "8.40")
    }

    @Test("The configured key reaches the wire")
    func sendsTheKeyOnTheRealCall() async throws {
        // makeRequest is asserted on directly elsewhere. This checks the header
        // still survives everything URLSession does to a request on the way out.
        reply(#"{"choices":[{"message":{"content":"ok"}}]}"#)

        _ = try await model(apiKey: "sk-test").respond(to: "hi", options: .structured)

        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(sent.url?.absoluteString == "https://example.test/v1/chat/completions")
    }

    @Test("A rejected key is unauthorized, not a generic failure")
    func mapsUnauthorized() async {
        reply(status: 401, #"{"error":{"message":"Incorrect API key provided"}}"#)

        await #expect(throws: OpenAICompatibleError.unauthorized("Incorrect API key provided")) {
            _ = try await model(apiKey: "sk-wrong").respond(to: "hi", options: .structured)
        }
    }

    @Test("Carries the server's own retry advice out of the 429")
    func mapsRateLimitWithRetryAfter() async {
        // Without this the caller has to guess a backoff the server already stated.
        reply(
            status: 429,
            headers: ["Retry-After": "12"],
            #"{"error":{"message":"Rate limit reached"}}"#
        )

        await #expect(throws: OpenAICompatibleError.rateLimited(retryAfter: 12)) {
            _ = try await model().respond(to: "hi", options: .structured)
        }
    }

    @Test("A 200 that isn't JSON is a malformed response, not a decode crash")
    func mapsNonJSONSuccess() async {
        // A proxy that answers 200 with an HTML holding page is a real thing.
        reply("<html>we are down for maintenance</html>")

        await #expect(throws: OpenAICompatibleError.self) {
            _ = try await model().respond(to: "hi", options: .structured)
        }
    }

    @Test("A valid answer with no choices in it fails instead of returning nothing")
    func mapsEmptyChoices() async {
        // The tempting bug is returning "" here: the caller then stores an empty
        // string as if the model had said it.
        reply(#"{"choices":[]}"#)

        await #expect(throws: OpenAICompatibleError
            .malformedResponse("the response carried no message content")) {
            _ = try await model().respond(to: "hi", options: .structured)
        }
    }

    @Test("A dead network is a transport failure, distinct from anything the server said")
    func mapsTransportFailure() async {
        StubURLProtocol.stub = .init(failure: URLError(.notConnectedToInternet))
        StubURLProtocol.lastRequest = nil

        await #expect(throws: OpenAICompatibleError.self) {
            _ = try await model().respond(to: "hi", options: .structured)
        }
    }
}

#endif
