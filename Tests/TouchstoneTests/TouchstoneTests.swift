import Testing
import Touchstone
import Foundation
import TouchstoneTesting

struct Expense: Assayable, Equatable {
    let amount: LenientDecimal
    let category: String

    static let jsonSchema = """
    { "amount": "decimal number, e.g. 8.40", "category": "string" }
    """
}

@Test("Decodes a clean reply into the requested type")
func decodesCleanReply() async throws {
    let model = FakeModel(reply: #"{"amount":8.40,"category":"food"}"#)
    let ai = Assayer(model: model)

    let expense = try await ai.value(Expense.self, from: "coffee, 8.40")

    #expect(expense.category == "food")
    #expect(expense.amount.value == Decimal(string: "8.40"))
}

@Test("Accepts a number the model decided to send as a string")
func acceptsStringifiedNumber() async throws {
    // Models flip between 8.40 and "8.40" from one call to the next. Accepting
    // both saves a repair round-trip; a plain Decimal field would fail here.
    let ai = Assayer(model: FakeModel(reply: #"{"amount":"8.40","category":"food"}"#))

    let expense = try await ai.value(Expense.self, from: "coffee")

    #expect(expense.amount.value == Decimal(string: "8.40"))
}

@Test("Digs JSON out of a reply wrapped in prose and code fences")
func survivesChattyModel() async throws {
    let chatty = """
    Sure! Here's the JSON you asked for:
    ```json
    {"amount":8.40,"category":"food"}
    ```
    Let me know if you need anything else.
    """
    let ai = Assayer(model: FakeModel(reply: chatty))

    let expense = try await ai.value(Expense.self, from: "coffee")

    #expect(expense.amount.value == Decimal(string: "8.40"))
}

@Test("Repairs a malformed reply and tells the model what was wrong")
func repairsMalformedReply() async throws {
    let model = FakeModel(replies: [
        .text("no idea, sorry"),
        .text(#"{"amount":8.40,"category":"food"}"#)
    ])
    let ai = Assayer(model: model)

    let expense = try await ai.value(Expense.self, from: "coffee")

    #expect(expense.amount.value == Decimal(string: "8.40"))
    #expect(model.receivedPrompts.count == 2)
    // The second prompt must carry the reason, or the retry is just a coin flip.
    #expect(model.receivedPrompts[1].contains("no JSON"))
}

@Test("Treats a hedged number as a repairable error, not as a value")
func repairsHedgedNumber() async throws {
    // "about 8.40" is the interesting case: guessing what it meant is how a
    // balance ends up wrong, so it becomes an error the model can fix.
    let model = FakeModel(replies: [
        .text(#"{"amount":"about 8.40","category":"food"}"#),
        .text(#"{"amount":8.40,"category":"food"}"#)
    ])
    let ai = Assayer(model: model)

    let expense = try await ai.value(Expense.self, from: "coffee")

    #expect(expense.amount.value == Decimal(string: "8.40"))
    #expect(model.receivedPrompts[1].contains("about 8.40"))
}

@Test("Gives up with a typed error instead of a half-built value")
func givesUpCleanly() async throws {
    let model = FakeModel(replies: [.text("nope"), .text("still nope"), .text("nope again")])
    let ai = Assayer(model: model, maximumRepairs: 2)

    await #expect(throws: AssayError.self) {
        _ = try await ai.value(Expense.self, from: "coffee")
    }
}

@Test("Parses numeric text exactly, and refuses text that only looks numeric")
func parsesNumbersExactly() throws {
    let exact = try #require(LenientDecimal(string: "8.40"))
    #expect(exact.value == Decimal(string: "8.40"))

    #expect(LenientDecimal(string: "about 8.40") == nil)
    #expect(LenientDecimal(string: "$8.40") == nil)
    #expect(LenientDecimal(string: "8.40 EUR") == nil)
    #expect(LenientDecimal(string: "") == nil)
}

@Test("Streams chunks in order")
func streamsChunks() async throws {
    let model = FakeModel(replies: [.chunks(["Hel", "lo, ", "world"])])
    let ai = Assayer(model: model)

    var text = ""
    for try await chunk in ai.stream("greet me") {
        text += chunk
    }

    #expect(text == "Hello, world")
}

@Test("Surfaces a truncated stream as an error, not as short text")
func surfacesTruncatedStream() async throws {
    struct Dropped: Error {}
    let model = FakeModel(replies: [.chunksThenFailure(["par", "tial"], Dropped())])
    let ai = Assayer(model: model)

    var text = ""
    await #expect(throws: Dropped.self) {
        for try await chunk in ai.stream("go") { text += chunk }
    }
    #expect(text == "partial")
}

@Test("A backend failure surfaces immediately instead of burning repair attempts")
func doesNotRepairBackendFailures() async throws {
    // A refusal or a dead socket is not a malformed answer. Re-asking the same
    // prompt is a guaranteed second failure, so only AssayError feeds the repair
    // loop — everything else goes straight to the caller. The second reply below
    // is a trap: if it is ever consumed, the loop retried something it shouldn't.
    struct Refused: Error {}
    let model = FakeModel(replies: [
        .failure(Refused()),
        .text(#"{"amount":8.40,"category":"food"}"#)
    ])
    let ai = Assayer(model: model, maximumRepairs: 2)

    await #expect(throws: Refused.self) {
        _ = try await ai.value(Expense.self, from: "coffee")
    }
    #expect(model.receivedPrompts.count == 1)
}

@Test("maximumRepairs of zero means one attempt and no repair")
func honoursZeroRepairs() async throws {
    let model = FakeModel(replies: [.text("not json at all")])
    let ai = Assayer(model: model, maximumRepairs: 0)

    await #expect(
        throws: AssayError.repairsExhausted(
            attempts: 1,
            lastReason: "the reply contained no JSON object"
        )
    ) {
        _ = try await ai.value(Expense.self, from: "coffee")
    }
    #expect(model.receivedPrompts.count == 1)
}

/// Records the options it was handed. `FakeModel` deliberately ignores them,
/// so proving that the convenience overloads pass defaults through needs a
/// model that looks. Used from a single task, hence no lock.
private final class OptionsRecorder: LanguageModel, @unchecked Sendable {

    private(set) var seen: [ModelOptions] = []

    func respond(to prompt: String, options: ModelOptions) async throws -> String {
        seen.append(options)
        return "ok"
    }

    func stream(_ prompt: String, options: ModelOptions) -> AsyncThrowingStream<String, Error> {
        seen.append(options)
        return AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }
}

@Test("Calling a model without options fills in the defaults")
func convenienceOverloadsFillInDefaultOptions() async throws {
    let model = OptionsRecorder()

    let answer = try await model.respond(to: "anything")
    for try await _ in model.stream("anything") {}

    #expect(answer == "ok")
    #expect(model.seen == [ModelOptions(), ModelOptions()])
}
