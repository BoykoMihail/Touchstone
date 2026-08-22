import Testing
import Touchstone
import TouchstoneTesting

struct Expense: Assayable, Equatable {
    let amount: Money
    let category: String

    static let jsonSchema = """
    { "amount": "string, decimal amount, e.g. \\"8.40\\"", "category": "string" }
    """
}

@Test("Decodes a clean reply into the requested type")
func decodesCleanReply() async throws {
    let model = FakeModel(reply: #"{"amount":"8.40","category":"food"}"#)
    let ai = Touchstone(model: model)

    let expense = try await ai.value(Expense.self, from: "coffee, 8.40")

    #expect(expense.category == "food")
    #expect(expense.amount == Money(string: "8.40"))
}

@Test("Digs JSON out of a reply wrapped in prose and code fences")
func survivesChattyModel() async throws {
    let chatty = """
    Sure! Here's the JSON you asked for:
    ```json
    {"amount":"8.40","category":"food"}
    ```
    Let me know if you need anything else.
    """
    let ai = Touchstone(model: FakeModel(reply: chatty))

    let expense = try await ai.value(Expense.self, from: "coffee")

    #expect(expense.amount == Money(string: "8.40"))
}

@Test("Repairs a malformed reply and tells the model what was wrong")
func repairsMalformedReply() async throws {
    let model = FakeModel(replies: [
        .text("no idea, sorry"),
        .text(#"{"amount":"8.40","category":"food"}"#)
    ])
    let ai = Touchstone(model: model)

    let expense = try await ai.value(Expense.self, from: "coffee")

    #expect(expense.amount == Money(string: "8.40"))
    #expect(model.receivedPrompts.count == 2)
    // The second prompt must carry the reason, or the retry is just a coin flip.
    #expect(model.receivedPrompts[1].contains("no JSON"))
}

@Test("Gives up with a typed error instead of a half-built value")
func givesUpCleanly() async throws {
    let model = FakeModel(replies: [.text("nope"), .text("still nope"), .text("nope again")])
    let ai = Touchstone(model: model, maximumRepairs: 2)

    await #expect(throws: AssayError.self) {
        _ = try await ai.value(Expense.self, from: "coffee")
    }
}

@Test("Refuses a float where money was expected")
func refusesFloatMoney() async throws {
    // 8.4 as a JSON number has already lost precision by the time it reaches us.
    let ai = Touchstone(model: FakeModel(reply: #"{"amount":8.4,"category":"food"}"#), maximumRepairs: 0)

    await #expect(throws: AssayError.self) {
        _ = try await ai.value(Expense.self, from: "coffee")
    }
}

@Test("Money parses without going through Double")
func moneyKeepsPrecision() throws {
    let money = try #require(Money(string: "8.40"))
    #expect(money.description == "8.4")
    #expect(Money(string: "about 8.40") == nil)
}

@Test("Streams chunks in order")
func streamsChunks() async throws {
    let model = FakeModel(replies: [.chunks(["Hel", "lo, ", "world"])])
    let ai = Touchstone(model: model)

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
    let ai = Touchstone(model: model)

    var text = ""
    await #expect(throws: Dropped.self) {
        for try await chunk in ai.stream("go") { text += chunk }
    }
    #expect(text == "partial")
}
