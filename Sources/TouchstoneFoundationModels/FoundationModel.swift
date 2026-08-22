import Foundation
import Touchstone

#if canImport(FoundationModels)
import FoundationModels

/// On-device backend built on Apple's `FoundationModels`.
///
/// Deliberately thin: everything interesting (typed output, repair, testing)
/// lives in the core, so this file only translates between two async worlds.
@available(iOS 26.0, macOS 26.0, *)
public struct FoundationModel: LanguageModel {

    private let instructions: String?

    public init(instructions: String? = nil) {
        self.instructions = instructions
    }

    public func respond(to prompt: String, options: ModelOptions) async throws -> String {
        let session = makeSession()
        let response = try await session.respond(to: prompt)
        return response.content
    }

    public func stream(_ prompt: String, options: ModelOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // The work runs inside a child task of the stream, so cancelling the
            // consumer cancels generation. That is the whole cancellation story:
            // no handles, no deinit bookkeeping.
            let task = Task {
                do {
                    let session = makeSession()
                    var delivered = ""
                    for try await partial in session.streamResponse(to: prompt) {
                        try Task.checkCancellation()
                        // FoundationModels yields the accumulated text; callers
                        // of `LanguageModel` expect deltas, so diff it here.
                        let whole = partial.content
                        if whole.hasPrefix(delivered) {
                            let delta = String(whole.dropFirst(delivered.count))
                            if !delta.isEmpty { continuation.yield(delta) }
                        } else {
                            continuation.yield(whole)
                        }
                        delivered = whole
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeSession() -> LanguageModelSession {
        if let instructions {
            return LanguageModelSession(instructions: instructions)
        }
        return LanguageModelSession()
    }
}

#else

/// Placeholder so the package builds on platforms without `FoundationModels`
/// (Linux CI, older SDKs). Calling it is a programmer error, not a runtime path.
public struct FoundationModel: LanguageModel {

    public init(instructions: String? = nil) {}

    public func respond(to prompt: String, options: ModelOptions) async throws -> String {
        throw FoundationModelUnavailable()
    }

    public func stream(_ prompt: String, options: ModelOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: FoundationModelUnavailable()) }
    }
}

public struct FoundationModelUnavailable: Error, CustomStringConvertible {
    public var description: String {
        "FoundationModels is not available on this platform."
    }
}

#endif
