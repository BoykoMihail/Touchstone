import Foundation
import Touchstone

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Errors

/// Why the on-device model can't be used at all.
///
/// This is a different question from "the model gave a bad answer", and it wants
/// a different UI: a feature you hide or an onboarding you show, not a retry.
public enum FoundationModelUnavailableReason: Sendable, Equatable, CustomStringConvertible {

    /// Built for a platform that has no `FoundationModels` framework (Linux, older SDKs).
    case unsupportedPlatform

    /// The hardware can't run it. Nothing the user can do.
    case deviceNotEligible

    /// The device could, but the user hasn't turned Apple Intelligence on.
    case notEnabled

    /// Enabled, but the model isn't downloaded or warmed up yet. Worth retrying later.
    case modelNotReady

    case other(String)

    public var description: String {
        switch self {
        case .unsupportedPlatform: return "this platform has no on-device model"
        case .deviceNotEligible: return "this device can't run the on-device model"
        case .notEnabled: return "Apple Intelligence is not enabled"
        case .modelNotReady: return "the on-device model isn't ready yet"
        case .other(let detail): return detail
        }
    }
}

/// Everything this backend can fail with, split by what a caller would *do* about it.
public enum FoundationModelError: Error, Sendable, Equatable, CustomStringConvertible {

    /// There is no usable model. Retrying the same call won't help.
    case unavailable(FoundationModelUnavailableReason)

    /// The safety guardrail rejected the prompt or the generated answer. Retrying
    /// the same prompt won't help either — which is why this is not an `AssayError`
    /// and does not feed the repair loop.
    case refused(String)

    /// Prompt plus history exceeded the context window. Send less.
    case promptTooLong

    /// Too many requests, or too many at once. Retrying later can help.
    case rateLimited

    /// Anything else, with the original description kept for the log.
    case failed(String)

    public var description: String {
        switch self {
        case .unavailable(let reason): return "on-device model unavailable: \(reason)"
        case .refused(let detail): return "the model refused: \(detail)"
        case .promptTooLong: return "the prompt exceeded the context window"
        case .rateLimited: return "rate limited"
        case .failed(let detail): return detail
        }
    }
}

// MARK: - Backend

#if canImport(FoundationModels)

/// On-device backend built on Apple's `FoundationModels`.
///
/// Deliberately thin: everything interesting (typed output, repair, testing)
/// lives in the core, so this file only has two jobs — translate between two
/// async worlds, and turn the framework's failures into errors a caller can
/// branch on.
@available(iOS 26.0, macOS 26.0, *)
public struct FoundationModel: LanguageModel {

    private let instructions: String?

    public init(instructions: String? = nil) {
        self.instructions = instructions
    }

    // MARK: Availability

    /// `nil` when the model is usable. Check this before showing the feature at
    /// all: an unavailable model is a product decision, not an error to display.
    ///
    ///     if let reason = FoundationModel.unavailableReason {
    ///         // hide the button, or explain what to switch on
    ///     }
    public static var unavailableReason: FoundationModelUnavailableReason? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .other("\(reason)")
            }
        @unknown default:
            return .other("unknown availability")
        }
    }

    // MARK: LanguageModel

    public func respond(to prompt: String, options: ModelOptions) async throws -> String {
        try Task.checkCancellation()
        if let reason = Self.unavailableReason {
            throw FoundationModelError.unavailable(reason)
        }

        do {
            let session = makeSession()
            let response = try await session.respond(
                to: prompt,
                options: Self.generationOptions(options)
            )
            return response.content
        } catch let error as CancellationError {
            // Cancellation is the caller's own decision arriving back — it is not
            // a model failure and must not be dressed up as one.
            throw error
        } catch {
            throw Self.mapped(error)
        }
    }

    public func stream(_ prompt: String, options: ModelOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // The work runs inside a child task of the stream, so cancelling the
            // consumer cancels generation. That is the whole cancellation story:
            // no handles, no deinit bookkeeping.
            let task = Task {
                if let reason = Self.unavailableReason {
                    continuation.finish(throwing: FoundationModelError.unavailable(reason))
                    return
                }
                do {
                    let session = makeSession()
                    var delivered = ""
                    let responses = session.streamResponse(
                        to: prompt,
                        options: Self.generationOptions(options)
                    )
                    for try await partial in responses {
                        try Task.checkCancellation()
                        // FoundationModels yields the accumulated text; callers
                        // of `LanguageModel` expect deltas, so diff it here.
                        let whole = partial.content
                        if whole.hasPrefix(delivered) {
                            let delta = String(whole.dropFirst(delivered.count))
                            if !delta.isEmpty { continuation.yield(delta) }
                        } else {
                            // The snapshot was rewritten rather than extended.
                            // Emitting it whole is wrong-ish but visible; silently
                            // dropping it would be wrong and invisible.
                            continuation.yield(whole)
                        }
                        delivered = whole
                    }
                    continuation.finish()
                } catch let error as CancellationError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: Self.mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Plumbing

    /// A fresh session per call, on purpose.
    ///
    /// `Assayer` re-sends the full context on every repair attempt, so a session
    /// that remembered the previous turn would show the model its own rejected
    /// answer twice — once in history, once in the repair prompt. Statelessness
    /// here is what keeps the repair loop honest.
    private func makeSession() -> LanguageModelSession {
        if let instructions {
            return LanguageModelSession(instructions: instructions)
        }
        return LanguageModelSession()
    }

    /// Carries our options across. Without this, `ModelOptions.structured`
    /// promises a temperature of zero and quietly delivers the default.
    private static func generationOptions(_ options: ModelOptions) -> GenerationOptions {
        GenerationOptions(
            temperature: options.temperature,
            maximumResponseTokens: options.maximumTokens
        )
    }

    /// Splits the framework's failures by what the caller can do next.
    ///
    /// The important line is `guardrailViolation`: a refusal is not a malformed
    /// answer, so it must not reach the repair loop — re-asking a rejected prompt
    /// three times is three guaranteed failures and three times the latency.
    private static func mapped(_ error: any Error) -> FoundationModelError {
        if let error = error as? FoundationModelError { return error }

        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize:
                return .promptTooLong
            case .guardrailViolation:
                return .refused("the safety guardrail rejected the prompt or the answer")
            case .rateLimited:
                return .rateLimited
            case .assetsUnavailable:
                return .unavailable(.modelNotReady)
            default:
                return .failed("\(generation)")
            }
        }

        return .failed("\(error)")
    }
}

#else

/// Placeholder so the package builds where `FoundationModels` doesn't exist
/// (Linux CI, older SDKs). Same shape as the real one, so cross-platform code
/// compiles against one API and fails at runtime with a reason, not a crash.
@available(iOS 26.0, macOS 26.0, *)
public struct FoundationModel: LanguageModel {

    public init(instructions: String? = nil) {}

    public static var unavailableReason: FoundationModelUnavailableReason? {
        .unsupportedPlatform
    }

    public func respond(to prompt: String, options: ModelOptions) async throws -> String {
        throw FoundationModelError.unavailable(.unsupportedPlatform)
    }

    public func stream(_ prompt: String, options: ModelOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream {
            $0.finish(throwing: FoundationModelError.unavailable(.unsupportedPlatform))
        }
    }
}

#endif
