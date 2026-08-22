import Foundation
import Touchstone

/// A model that answers from a script. Deterministic, offline, instant.
///
/// This is the target that makes LLM features testable: the interesting cases
/// aren't "the model answered correctly", they're "the model wrapped JSON in
/// prose", "the stream died halfway", "the second attempt succeeded".
public final class FakeModel: LanguageModel, @unchecked Sendable {

    public enum Reply: Sendable {
        /// A complete response.
        case text(String)
        /// A response delivered in chunks — order preserved.
        case chunks([String])
        /// A failure instead of a response.
        case failure(any Error)
        /// Chunks, then a failure: the truncated-stream case.
        case chunksThenFailure([String], any Error)
    }

    private var replies: [Reply]
    private let lock = NSLock()

    /// Every prompt this model was asked, in order. Assert on it to check that
    /// a repair attempt actually included the decoder's complaint.
    public private(set) var receivedPrompts: [String] = []

    /// Replies are consumed in order. Running out is a test bug, and it throws
    /// rather than silently repeating the last answer.
    public init(replies: [Reply]) {
        self.replies = replies
    }

    public convenience init(reply: String) {
        self.init(replies: [.text(reply)])
    }

    public func respond(to prompt: String, options: ModelOptions) async throws -> String {
        let reply = try next(for: prompt)
        switch reply {
        case .text(let text):
            return text
        case .chunks(let chunks):
            return chunks.joined()
        case .failure(let error):
            throw error
        case .chunksThenFailure(_, let error):
            throw error
        }
    }

    public func stream(_ prompt: String, options: ModelOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let reply: Reply
            do {
                reply = try next(for: prompt)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            switch reply {
            case .text(let text):
                continuation.yield(text)
                continuation.finish()
            case .chunks(let chunks):
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            case .chunksThenFailure(let chunks, let error):
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish(throwing: error)
            }
        }
    }

    private func next(for prompt: String) throws -> Reply {
        lock.lock()
        defer { lock.unlock() }
        receivedPrompts.append(prompt)
        guard !replies.isEmpty else {
            throw FakeModelError.ranOutOfReplies(afterPrompts: receivedPrompts.count)
        }
        return replies.removeFirst()
    }
}

public enum FakeModelError: Error, Sendable, Equatable {
    /// The code under test made more calls than the script allowed. Usually
    /// means the repair loop ran more often than you expected — which is worth
    /// knowing.
    case ranOutOfReplies(afterPrompts: Int)
}
