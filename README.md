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

The package's own suite works the same way: nothing touches the network. There is one exception, and it is opt-in, because a library that has never spoken to a real model only works in its own imagination:

```bash
brew install ollama && ollama serve
ollama pull llama3.2:1b
TOUCHSTONE_LIVE=1 swift test
```

| Verified against | How |
|---|---|
| Ollama, `llama3.2:1b`, CPU-only | `.ollama(model:)`, no key — typed output, repair and a 21-chunk stream all worked |
| Apple `FoundationModels`, iOS 26 simulator | Reports itself **available**, then refuses every request on the guardrail — see below |
| Apple `FoundationModels`, iPhone 17, iOS 26.6.1 | Reports `.notEnabled` — and on that device it cannot be enabled at all, see below |

Two things that run says out loud. A one-billion-parameter model does produce
usable JSON through the repair loop, which is better than I expected. And asked
to "reply with the single word: pong", it replied "game" — it played word
association instead of following the instruction. Nothing was wrong with the
call; the model simply didn't do as it was told. That is the entire reason this
library exists: without a schema and a check, "game" is what reaches your app.

### 5. "No model" is a product decision, not an error

An on-device model isn't always there. The device may not be eligible, the user may not have switched Apple Intelligence on, or the model may still be downloading — and those are three different pieces of UI, none of which is an error message.

```swift
if let reason = FoundationModel.unavailableReason {
    switch reason {
    case .deviceNotEligible:  hideTheFeature()        // nothing the user can do
    case .notEnabled:         explainHowToTurnItOn()  // an onboarding step
    case .modelNotReady:      offerToRetryLater()     // still downloading
    default:                  hideTheFeature()
    }
}
```

**Availability is not a promise, though.** In the iOS 26 simulator
`unavailableReason` is `nil` — the model says it is there — and every single
request then comes back as a guardrail refusal. Not a suspicious prompt:
"lunch, 12.50" is refused, and so is "describe this expense in two sentences".
Availability and willingness are two different questions, and the framework
only answers the first. Verify the on-device backend on real hardware; a green
availability check in a simulator means nothing.

**On real hardware the check is honest, and the answer can be permanent.** The
same demo on an iPhone 17 running iOS 26.6.1 reports `.notEnabled` rather than
pretending. What makes that worth writing down is *why*: Apple Intelligence
requires the device language and the Siri language to match, and to be one of a
supported set — which does not include Russian, Ukrainian, Polish, Greek,
Hindi, Arabic or Hebrew, among others. So on a phone whose owner reads Russian,
this feature is not "switched off pending onboarding". It is unavailable, and no
amount of explaining where the toggle lives will change that.

Which is the whole argument for treating `unavailableReason` as product input
rather than an error path. `.notEnabled` looks like something you can talk the
user into fixing. For a large share of the world's phones it is not.

That is also the accidental proof of the paragraph below. Each of those refusals
cost exactly one call — `attempts: 0`, one named error — because a refusal never
enters the repair loop. Had it, every one of them would have been three failed
requests instead of one.

Check it once, before you show the entry point. Calling anyway is safe — you get a typed `FoundationModelError.unavailable(reason)` rather than an opaque framework failure — but by then the user has already tapped a button that was never going to work.

The same split runs through the errors. A guardrail refusal, a prompt over the context window and a rate limit are separate cases, because the caller does something different about each. And a refusal deliberately **does not** feed the repair loop: re-asking a prompt the model just refused is three guaranteed failures and three times the latency.

## Examples

`Examples/TouchstoneDemo` is a small SwiftUI app. Open it, press one button, and
watch a sentence become an `Expense`.

It defaults to the **fake** backend, which is the whole point: it works the
instant you open it, with no model to download, no key and no server. Three
scripted scenarios — a clean answer, one that needs a repair, and one that never
becomes valid. The third is the one to look at, because it ends in an error
rather than a plausible zero.

Apple Intelligence, Ollama and a cloud key are the other three options, and each
states in one line what it needs.

## Design

Three targets, on purpose:

| Target | Depends on | Why |
|---|---|---|
| `Touchstone` | nothing | Core. Runs anywhere Swift runs, including Linux CI. |
| `TouchstoneTesting` | `Touchstone` | Fake model, snapshot helpers. |
| `TouchstoneFoundationModels` | Apple's `FoundationModels` | The on-device backend. |
| `TouchstoneOpenAICompatible` | Foundation only | Any server speaking the OpenAI chat-completions dialect. |

The core knows nothing about any specific model. `LanguageModel` is a two-method protocol, so an on-device model, a cloud API, or a fake are interchangeable — including in tests, which is the whole point.

The second backend is one implementation for OpenAI, Ollama, LM Studio, llama.cpp's server and Groq: they differ by a base URL and whether a key is needed.

```swift
// A hosted model
let hosted = OpenAICompatibleModel(configuration: .init(
    baseURL: URL(string: "https://api.openai.com/v1")!,
    model: "gpt-4o-mini",
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
))

// Or nothing but localhost: no key, no account, no network
let local = OpenAICompatibleModel(configuration: .ollama(model: "llama3.2"))
```

It exists mostly to keep the previous paragraph honest. A protocol with one implementation is a guess; `LanguageModel` had to meet something that wasn't designed alongside it. Streaming needs `URLSession.bytes(for:)`, which non-Apple Foundation doesn't ship, so on Linux the streaming call returns a named error rather than failing to link — and the target still builds there, which is what proves the rest of it carries no Apple dependency.

## Status

`0.2.0` — early, but real. Everything in this README is implemented and covered by tests: typed output with bounded repair, `LenientDecimal`, streaming with cancellation, the fake model, the on-device backend with its availability and error split, and a second backend for any OpenAI-compatible server. `Examples/TouchstoneDemo` runs on the fake backend with no model, no key and no server.

What isn't here yet: guided generation on backends that support constrained decoding (where the repair loop should get out of the way entirely), a native Anthropic backend on `/v1/messages`, streaming of typed output, and DocC pages.

The API may still change while the version is `0.x`; breaking changes will be called out in the changelog.

## Requirements

Swift 6.0+. The core has no platform requirements; the `FoundationModels` backend requires iOS 26 / macOS 26 and a device with Apple Intelligence.

## Licence

MIT
