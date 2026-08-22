# Touchstone

[![CI](https://github.com/BoykoMihail/Touchstone/actions/workflows/ci.yml/badge.svg)](https://github.com/BoykoMihail/Touchstone/actions/workflows/ci.yml)

**Typed, testable, cancellable LLM calls in Swift.**

A touchstone is the stone jewellers rub gold against to check it's really gold. This library does that for model output: you declare the Swift type you expect, and Touchstone makes sure that's what you get — or gives you a clear error instead of plausible-looking garbage.

```swift
struct Expense: Assayable {
    let amount: LenientDecimal
    let category: String

    static let jsonSchema = """
    { "amount": "decimal number, e.g. 8.40",
      "category": "string, one of: food, transport, other" }
    """
}

let ai = Assayer(model: FoundationModel())
let expense = try await ai.value(Expense.self, from: "coffee and a croissant, 8 euro 40")

expense.amount.value    // 8.40 as Decimal
expense.category        // "food"
```

No prompt engineering for the format, no hand-written JSON parsing, no defaults papering over a bad answer.

## Why this exists

Most Swift LLM libraries solve *access* to the model. Touchstone solves what happens after: the model answered, and now you have a `String` that may or may not be what your app needs.

In practice that means four problems, and Touchstone is four answers.

### 1. You get your type, not a string

You describe the shape you want. Touchstone puts the format instructions in the prompt, decodes the response, and validates it. If the model returns something that doesn't decode, Touchstone re-asks it — with the decoding error included, so the second attempt is informed rather than hopeful. Retries are bounded and configurable; when they run out you get a typed error, never a half-parsed object.

### 2. Numbers stay numbers

Credit where it's due: Foundation already decodes `Decimal` from a JSON number without losing precision — `8.40` really does come back as `8.4`, not `8.400000000000000355`. The decoder is not the problem.

The model is. Asked for an amount it writes `8.40` on one call and `"8.40"` on the next, and a plain `Decimal` field fails on the second one. Sometimes it writes `"about 8.40"` or `"$8.40"`, which is worse, because that's the point where hand-rolled parsing quietly returns zero.

`LenientDecimal` accepts either form exactly, and refuses anything that merely looks numeric. Refusals become a repair attempt with the reason attached, so the model gets a chance to fix it. What you never get is a default — a silent zero in a numeric field is a lie with a clean conscience.

There is no currency type here, and no rounding or formatting: that's your domain, not a library about model output.

### 3. Streaming that cancels itself

Streamed responses are an `AsyncThrowingStream`, driven by structured concurrency. Drop the task — the generation stops. Leave the screen — the task is cancelled with it. No handles to store, no updates arriving for a view controller that's already gone.

```swift
for try await chunk in ai.stream("summarise this transaction history") {
    text += chunk
}
```

### 4. Tests that don't need a model

`TouchstoneTesting` ships a deterministic fake:

```swift
let ai = Assayer(model: FakeModel(replies: [.text(#"{"amount":"8.40","category":"food"}"#)]))
```

Which means you can unit-test the interesting cases — malformed output, a truncated stream, a model that fails on the third token, a rate-limit error — in milliseconds, on CI, with no network and no device. Record real responses once, replay them forever.

## Design

Three targets, on purpose:

| Target | Depends on | Why |
|---|---|---|
| `Touchstone` | nothing | Core. Runs anywhere Swift runs, including Linux CI. |
| `TouchstoneTesting` | `Touchstone` | Fake model, snapshot helpers. |
| `TouchstoneFoundationModels` | Apple's `FoundationModels` | The on-device backend. |

The core knows nothing about any specific model. `LanguageModel` is a two-method protocol, so an on-device model, a cloud API, or a fake are interchangeable — including in tests, which is the whole point.

## Status

Early. The API in this README is the target design, and it's what the code is being built against — README-first, deliberately. Follow along or open an issue if you'd design it differently.

## Requirements

Swift 6.0+. The core has no platform requirements; the `FoundationModels` backend requires iOS 26 / macOS 26 and a device with Apple Intelligence.

## Licence

MIT
