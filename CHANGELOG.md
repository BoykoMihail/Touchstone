# Changelog

All notable changes to Touchstone are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the major version is `0`, the public API may change in a minor release;
anything breaking is listed under **Changed** or **Removed** with the reason.

## [Unreleased]

### Notes

- **The on-device backend was verified answering on real hardware**, which
  corrects two things written under 0.2.0. iPhone 17, iOS 26.6.1, Apple
  Intelligence on: typed output in one attempt with no repair, and a
  three-chunk stream.
  - "on that device it cannot be enabled" was too strong. It can. The blocker is
    the language the phone is in, not the phone. Apple Intelligence needs the
    device and Siri languages to match down to the regional variant — with the
    phone in English but the region still Russia, the device reads as
    "English (Russia)" against Siri's "English (United States)", they do not
    match, and no toggle appears at all. Match the region and the feature works.
    `.notEnabled` is still a product state worth branching on, but it means
    "not in the language this person reads", not "never on this hardware".
  - the guardrail refusals were attributed to the model. They belong to the
    **simulator**: the prompts the iOS 26 simulator refused every time were
    answered on the first attempt by the device.
- Apple's on-device model returns its JSON wrapped in a Markdown code fence, in
  the typed call and in the stream both. Nothing asked it to. This is the first
  confirmation of the lenient extraction against a real model rather than the
  fake one.
- Between enabling Apple Intelligence and the model finishing its download, the
  backend reported `.notEnabled` rather than `.modelNotReady`. Read availability
  when you are about to show the entry point, not once at launch.

## [0.2.0] — 2026-09-07

The release that stops this being one implementation with a protocol drawn
around it. Two backends now, and an app you can run before you have a model.

### Added

- `TouchstoneOpenAICompatible` — a second backend, for any server speaking the
  OpenAI chat-completions dialect: OpenAI, Ollama, LM Studio, llama.cpp's server,
  Groq. One base URL and an optional key apart.
- `OpenAICompatibleModel.Configuration.ollama(model:)` — the local default, so the
  library can be tried with no key and no account.
- `OpenAICompatibleError` — the same categories as the on-device backend
  (`unauthorized`, `rateLimited`, `promptTooLong`, `refused`, `serverError`,
  `transport`, `malformedResponse`), because a caller that has to write different
  error handling per backend has no abstraction, only two clients.
- `respond(to:)` and `stream(_:)` on `LanguageModel` — the same two calls without
  `options:`. A protocol requirement cannot carry default arguments, so the first
  call written directly against the protocol, rather than through `Assayer`, did
  not compile. That is evidence about the shape of the API, not a matter of taste.
- A coverage job in CI with a 70% line gate over `Sources/`. The real figure on
  a runner is 74.6%; the gap is not slack. Streaming over a live `URLSession` is
  only exercised by the opt-in live tests, and `TouchstoneFoundationModels`
  needs iOS 26 on eligible hardware, which no runner has. The gate is there to
  catch a target arriving with no tests, not to serve as a quality score. When
  the gate fails it prints per-file coverage, so the answer is which file
  rather than which percentage.
- `Examples/TouchstoneDemo` — a SwiftUI app that runs before you have a model.
  Defaults to the fake backend with three scenarios (clean, one repair, never
  valid), and offers Apple Intelligence, Ollama or a cloud key. A twelve-line
  decorator in the demo shows every reply the model gave, rejected ones
  included.

### Notes

- On an iPhone 17 (iOS 26.6.1) the same backend reports `.notEnabled`, and on
  that device it cannot be enabled: Apple Intelligence needs the device and Siri
  languages to match and to be one of a supported set, which excludes Russian
  among others. `.notEnabled` therefore does not always mean "the user could
  turn this on" — sometimes it means "never, on this phone". Another reason the
  reason code belongs in product decisions rather than in an error path.
- Apple's on-device model reports itself **available** in the iOS 26 simulator
  and then refuses every request on the guardrail — "lunch, 12.50" included, and
  a plain prose prompt too. `unavailableReason` answers whether the model is
  there, not whether it will answer. Verify that backend on real hardware.
  Incidentally this confirmed a decision made from the documentation in 0.1.0:
  because a refusal never enters the repair loop, each of those cost one call
  and one named error rather than three failed requests.

- This is what turns "swap the model" from a design claim into a demonstrated one:
  `LanguageModel` had to meet an implementation it wasn't designed alongside. It
  fit, with one exception worth recording — streaming needs
  `URLSession.bytes(for:)`, which non-Apple Foundation doesn't ship, so on Linux
  the streaming call returns `.streamingUnavailable` instead of a byte stream.
- Everything except the two `URLSession` calls is pure and covered by tests:
  building the request, reading an SSE line, turning a status code into an error.
  The calls themselves are covered too, through a stub `URLProtocol` — so the
  whole non-streaming path is exercised end to end. No test touches the network
  unless you ask it to: `TOUCHSTONE_LIVE=1 swift test` runs three checks against
  a real model, defaulting to Ollama on localhost.

## [0.1.0] — 2026-08-30

First tagged version. The API described in the README is implemented and tested.

### Added

- `Assayer` — the entry point. `value(_:from:options:)` asks for a typed value and
  returns it or throws; there is no path that returns a partially populated object.
  A malformed answer is re-asked with the decoder's complaint attached, so the second
  attempt is informed rather than hopeful. Repairs are bounded by `maximumRepairs`.
- `Assayable` — the protocol a type conforms to in order to be requested from a model.
  Its `jsonSchema` is deliberately prose rather than a formal schema document: small
  models follow a compact example far better than a specification.
- `AssayError` — every case is something a caller can act on, and none of them is a
  value.
- `LenientDecimal` — decodes from a JSON number **or** a numeric string, exactly, and
  from nothing else. `"about 8.40"` and `"$8.40"` become a repairable error rather than
  a silent zero. No currency, no rounding, no formatting: those belong to your domain.
- `Assayer.stream(_:options:)` — an `AsyncThrowingStream` driven by structured
  concurrency. Cancelling the consuming task stops generation; there is no handle to
  store and nothing to remember to tear down.
- `TouchstoneTesting` with `FakeModel` — scripted replies (`.text`, `.chunks`,
  `.failure`, `.chunksThenFailure`) and a record of every prompt the model received,
  so a repair attempt can be asserted on rather than assumed.
- `TouchstoneFoundationModels` with `FoundationModel` — the on-device backend built on
  Apple's `FoundationModels`.
- `FoundationModel.unavailableReason` — `nil` when the model is usable, otherwise a
  reason a caller can branch on: the device isn't eligible, Apple Intelligence isn't
  enabled, or the model isn't ready. Check it before showing the feature at all.
- `FoundationModelError` — failures split by what the caller can do next: `unavailable`,
  `refused`, `promptTooLong`, `rateLimited`, `failed`. A guardrail refusal is
  deliberately not an `AssayError` and does not feed the repair loop, because re-asking
  a rejected prompt is a guaranteed second failure.
- CI on macOS and on Linux. The Linux job exists to keep a promise from the README:
  the core target depends on no platform SDK, so it has to build and test where
  `FoundationModels` does not exist at all. If that job goes red, the core has grown an
  Apple dependency — a design regression, not a CI blip.

### Notes

- The core has no dependencies. `Touchstone` is the only target you need to build a
  backend against; `LanguageModel` is a two-method protocol on purpose.
- Only one real backend ships in this version, so "swap the model" is a design claim
  rather than a demonstrated one. A second, OpenAI-compatible backend is next.

[Unreleased]: https://github.com/BoykoMihail/Touchstone/compare/0.1.0...HEAD
[0.1.0]: https://github.com/BoykoMihail/Touchstone/releases/tag/0.1.0
