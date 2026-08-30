import Foundation
import Testing
import Touchstone
import TouchstoneOpenAICompatible

// The only tests here that talk to a real model. Off unless you ask for them:
//
//     TOUCHSTONE_LIVE=1 swift test
//
// Defaults point at Ollama on localhost, so this costs nothing and needs no
// account:
//
//     brew install ollama && ollama serve
//     ollama pull llama3.2:1b
//
// Override with TOUCHSTONE_LIVE_BASE_URL, TOUCHSTONE_LIVE_MODEL and
// TOUCHSTONE_LIVE_API_KEY to point at a hosted model instead.
//
// These are deliberately not part of the normal suite. A test that needs a
// running server is a test that goes red for reasons that have nothing to do
// with the change under review, and a suite people learn to ignore is worse
// than no suite. But a library that has never once spoken to a real model is
// a library that only works in its own imagination — so the check exists, it
// just runs on request.

private enum Live {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TOUCHSTONE_LIVE"] != nil
    }

    static var model: OpenAICompatibleModel {
        let environment = ProcessInfo.processInfo.environment
        let baseURL = environment["TOUCHSTONE_LIVE_BASE_URL"]
            .flatMap(URL.init(string:))
            ?? URL(string: "http://localhost:11434/v1")!

        return OpenAICompatibleModel(configuration: .init(
            baseURL: baseURL,
            model: environment["TOUCHSTONE_LIVE_MODEL"] ?? "llama3.2:1b",
            apiKey: environment["TOUCHSTONE_LIVE_API_KEY"]
        ))
    }
}

private struct Capital: Assayable, Equatable {
    let city: String

    static let jsonSchema = """
    { "city": "string, the name of the city only" }
    """
}

@Suite(.enabled(if: Live.isEnabled), .serialized)
struct LiveModelTests {

    @Test("A real model answers at all")
    func respondsWithText() async throws {
        let text = try await Live.model.respond(
            to: "Reply with the single word: pong",
            options: .structured
        )

        print("live respond →", text)
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("A real model streams, in more than one piece")
    func streamsChunks() async throws {
        // The piece the unit tests cannot reach: a genuine SSE stream, with
        // whatever chunk boundaries the server felt like.
        var chunks: [String] = []
        for try await chunk in Live.model.stream("Count from one to five, in words.") {
            chunks.append(chunk)
        }

        let text = chunks.joined()
        print("live stream → \(chunks.count) chunks: \(text)")
        #expect(!text.isEmpty)
        #expect(chunks.count > 1, "a stream that arrives in one piece isn't streaming")
    }

    @Test("A real model produces a value of the requested type")
    func decodesATypedValue() async throws {
        // The whole library in one call: instructions go out, JSON comes back,
        // a malformed answer is repaired rather than returned. Small local
        // models are exactly the ones that need the repair loop, which is why
        // this is the interesting test and not the first one.
        let ai = Assayer(model: Live.model, maximumRepairs: 3)

        let answer = try await ai.value(Capital.self, from: "What is the capital of France?")

        print("live typed →", answer.city)
        #expect(answer.city.localizedCaseInsensitiveContains("paris"))
    }
}
