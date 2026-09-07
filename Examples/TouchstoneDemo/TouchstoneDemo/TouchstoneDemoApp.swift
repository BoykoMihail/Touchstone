import Observation
import SwiftUI
import Touchstone
import TouchstoneFoundationModels
import TouchstoneOpenAICompatible
import TouchstoneTesting

@main
struct TouchstoneDemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// MARK: - The value we want out of a sentence

/// One expense, the way an app would actually want it: a number it can add up
/// and a category it can group by — not a paragraph about coffee.
nonisolated struct Expense: Assayable, Equatable {

    let amount: LenientDecimal
    let category: String

    /// The schema is prose on purpose. It is sent to the model verbatim, and a
    /// model follows a short example better than it follows JSON Schema.
    static let jsonSchema = """
    { "amount": "decimal number, e.g. 8.40", "category": "one word, e.g. food" }
    """
}

// MARK: - Watching the model without changing the library

/// Wraps any backend and reports each reply as it arrives.
///
/// This exists so the demo can show what the model actually said, including the
/// answers that were rejected. Worth noticing how little it takes: `LanguageModel`
/// has two methods and no associated types, so decorating it is a dozen lines
/// rather than a redesign. A fatter protocol could not be observed this cheaply.
nonisolated final class RecordingModel: LanguageModel, @unchecked Sendable {

    private let wrapped: any LanguageModel
    private let onReply: @Sendable (String) -> Void

    init(wrapping wrapped: any LanguageModel, onReply: @escaping @Sendable (String) -> Void) {
        self.wrapped = wrapped
        self.onReply = onReply
    }

    func respond(to prompt: String, options: ModelOptions) async throws -> String {
        let reply = try await wrapped.respond(to: prompt, options: options)
        onReply(reply)
        return reply
    }

    func stream(_ prompt: String, options: ModelOptions) -> AsyncThrowingStream<String, Error> {
        wrapped.stream(prompt, options: options)
    }
}

// MARK: - Which backend

enum BackendChoice: String, CaseIterable, Identifiable {
    case fake
    case appleIntelligence
    case ollama
    case cloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fake: return "Fake"
        case .appleIntelligence: return "Apple Intelligence"
        case .ollama: return "Ollama"
        case .cloud: return "Cloud"
        }
    }

    var requirement: String {
        switch self {
        case .fake: return "Nothing. Scripted replies, instant, offline — this is the default so the demo works the moment you open it."
        case .appleIntelligence: return "iOS 26 on eligible hardware, Apple Intelligence switched on."
        case .ollama: return "A local Ollama server on port 11434. Try: ollama run llama3.2:1b"
        case .cloud: return "Your own key. It is held in memory for this run only and never written anywhere."
        }
    }
}

/// The three cases worth showing. A demo that only shows the happy path is a
/// screenshot; the repair loop is the actual product.
nonisolated enum FakeScenario: String, CaseIterable, Identifiable {
    case clean
    case oneRepair
    case hopeless

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: return "Clean"
        case .oneRepair: return "One repair"
        case .hopeless: return "Never valid"
        }
    }

    var explanation: String {
        switch self {
        case .clean: return "The model answers with usable JSON first time."
        case .oneRepair: return "The first answer is prose. It is rejected, the complaint is sent back, and the second answer decodes."
        case .hopeless: return "Every answer is prose. After the repair budget runs out you get an error — not a zero, not a nil."
        }
    }

    var replies: [FakeModel.Reply] {
        switch self {
        case .clean:
            return [.text(#"{"amount":8.40,"category":"food"}"#)]
        case .oneRepair:
            return [
                .text("Sure! That comes to about 8.40 euros, and I'd file it under food."),
                // Note the string, not the number. Models flip between the two
                // between calls; LenientDecimal takes either rather than
                // spending another round trip on it.
                .text(#"{"amount":"8.40","category":"food"}"#)
            ]
        case .hopeless:
            return [
                .text("That'll be roughly eight euros forty."),
                .text("Approximately 8.40 EUR — food, I think."),
                .text("Somewhere around 8-9 euros for food.")
            ]
        }
    }
}

nonisolated enum DemoError: Error, CustomStringConvertible {
    case cannotUseBackend(String)

    var description: String {
        switch self {
        case .cannotUseBackend(let why): return why
        }
    }
}

// MARK: - State

@MainActor
@Observable
final class DemoModel {

    // Input
    var backend: BackendChoice = .fake
    var scenario: FakeScenario = .oneRepair
    var sentence = "coffee and a croissant, 8 euros 40"

    var ollamaModel = "llama3.2:1b"
    var cloudBaseURL = "https://api.openai.com/v1"
    var cloudModel = "gpt-4o-mini"
    var cloudKey = ""

    // Typed output
    var replies: [String] = []
    var expense: Expense?
    var failure: String?
    var isRunning = false

    /// Attempts, not repairs: the first call is an attempt too.
    var attempts: Int { replies.count }

    // Streaming
    var streamed = ""
    var chunkCount = 0
    var streamFailure: String?
    private(set) var streamTask: Task<Void, Never>?
    var isStreaming: Bool { streamTask != nil }

    /// Whatever this backend needs and hasn't got, in one line — checked before
    /// a run rather than surfaced as a failure afterwards.
    var blocker: String? {
        switch backend {
        case .fake:
            return nil
        case .appleIntelligence:
            if #available(iOS 26.0, *) {
                return FoundationModel.unavailableReason?.description
            }
            return "this device runs an iOS older than 26, which has no on-device model"
        case .ollama:
            return nil
        case .cloud:
            return cloudKey.isEmpty ? "no API key entered" : nil
        }
    }

    /// The on-device model reports itself available in a simulator and then
    /// refuses everything. Without this line the demo looks broken, and the
    /// reader blames the library rather than the runtime.
    var failureHint: String? {
        guard backend == .appleIntelligence,
              let failure, failure.contains("refused") else { return nil }
        return "Running in a simulator? There the on-device model says it is available and then refuses every request, benign ones included. Availability and willingness are different questions — check this backend on real hardware."
    }

    func extract() async {
        replies = []
        expense = nil
        failure = nil
        isRunning = true
        defer { isRunning = false }

        do {
            let base = try makeModel()
            let watched = RecordingModel(wrapping: base) { [weak self] reply in
                Task { @MainActor in self?.replies.append(reply) }
            }
            // maximumRepairs: 2 means up to three attempts in total.
            let ai = Assayer(model: watched, options: .structured, maximumRepairs: 2)
            expense = try await ai.value(Expense.self, from: sentence)
        } catch {
            failure = String(describing: error)
        }
    }

    func startStreaming() {
        streamed = ""
        chunkCount = 0
        streamFailure = nil

        let model: any LanguageModel
        do {
            model = try makeStreamingModel()
        } catch {
            streamFailure = String(describing: error)
            return
        }

        let prompt = "Describe this expense in two sentences: \(sentence)"

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                // No `options:` here — that overload landed because this exact
                // call did not compile without it.
                for try await chunk in model.stream(prompt) {
                    self.streamed += chunk
                    self.chunkCount += 1
                }
            } catch is CancellationError {
                self.streamFailure = "cancelled — cancelling the task stopped generation, with no handle to remember"
            } catch {
                self.streamFailure = String(describing: error)
            }
            self.streamTask = nil
        }
    }

    func cancelStreaming() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Building a backend

    private func makeModel() throws -> any LanguageModel {
        switch backend {
        case .fake:
            return FakeModel(replies: scenario.replies)

        case .appleIntelligence:
            if #available(iOS 26.0, *) {
                if let reason = FoundationModel.unavailableReason {
                    throw DemoError.cannotUseBackend("on-device model unavailable: \(reason)")
                }
                return FoundationModel(
                    instructions: "You extract structured data. Reply with JSON only, no prose."
                )
            }
            throw DemoError.cannotUseBackend("needs iOS 26 or newer")

        case .ollama:
            return OpenAICompatibleModel(configuration: .ollama(model: ollamaModel))

        case .cloud:
            guard let url = URL(string: cloudBaseURL) else {
                throw DemoError.cannotUseBackend("that base URL doesn't parse")
            }
            guard !cloudKey.isEmpty else {
                throw DemoError.cannotUseBackend("no API key entered")
            }
            return OpenAICompatibleModel(
                configuration: .init(baseURL: url, model: cloudModel, apiKey: cloudKey)
            )
        }
    }

    /// The fake's scripted answers arrive whole, which makes for a dull stream.
    /// For the streaming tab it hands back chunks instead.
    private func makeStreamingModel() throws -> any LanguageModel {
        guard backend == .fake else { return try makeModel() }
        return FakeModel(replies: [
            .chunks([
                "A coffee ", "and a croissant, ", "eight euros forty. ",
                "Filed under food, ", "paid this morning."
            ])
        ])
    }
}
