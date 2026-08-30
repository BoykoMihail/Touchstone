# Changelog

All notable changes to Touchstone are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the major version is `0`, the public API may change in a minor release;
anything breaking is listed under **Changed** or **Removed** with the reason.

## [Unreleased]

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
