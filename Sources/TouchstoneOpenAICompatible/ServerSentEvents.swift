import Foundation

/// One line of a server-sent-events stream, reduced to what a chat completion
/// actually uses.
///
/// Splitting the byte stream into lines is left to Foundation's
/// `AsyncLineSequence`: it already handles `\n`, `\r\n` and multi-byte
/// characters landing across a chunk boundary, and reimplementing that is a
/// good way to corrupt one answer in a thousand. What is *not* left to
/// Foundation is deciding what a line means — that's this type, and it is pure,
/// so every odd line a real server sends can be a unit test.
enum ServerSentEvent: Equatable {

    /// A `data:` payload that isn't the terminator.
    case data(String)

    /// The `[DONE]` sentinel: the server is finished and will send nothing more.
    case done
}

extension ServerSentEvent {

    /// Reads a single line. Returns `nil` for the lines that carry no payload:
    /// the blanks between events, the `:` comments some proxies send as
    /// keep-alives, and fields other than `data`, which this dialect doesn't use.
    static func from(line: String) -> ServerSentEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { return nil }
        guard trimmed.hasPrefix("data:") else { return nil }

        let payload = trimmed.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return payload == "[DONE]" ? .done : .data(payload)
    }
}
