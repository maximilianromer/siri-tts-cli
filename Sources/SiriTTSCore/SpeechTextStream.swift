import Foundation

public enum SpeechTextToken: Equatable, Sendable {
    case text(String)
    case utterance(String)
    var text: String { switch self { case .text(let value), .utterance(let value): return value } }
}

/// A bounded, cancellable channel for text arriving from a model or pipe.
/// Append preserves text exactly; finish marks end-of-input. The native service
/// decides sentence boundaries for text; appendUtterance forces a boundary.
public final class SpeechTextStream: @unchecked Sendable {
    private let condition = NSCondition()
    private var queue: [SpeechTextToken] = []
    private var readIndex = 0
    private var closed = false
    private var failure: Error?
    private var totalBytes = 0
    public let maximumTextBytes: Int
    public init(maximumTextBytes: Int = 128_000) { self.maximumTextBytes = max(1, maximumTextBytes) }
    public func append(_ text: String) throws { try enqueue(.text(text)) }
    public func appendUtterance(_ text: String) throws { try enqueue(.utterance(text)) }
    private func enqueue(_ token: SpeechTextToken) throws {
        let text = token.text
        try condition.withLock {
            guard !closed else { throw CLIError("Text stream is closed", code: .usage) }
            guard text.utf8.count <= maximumTextBytes - totalBytes else { throw CLIError("Text stream exceeds its byte limit", code: .usage) }
            totalBytes += text.utf8.count
            if !text.isEmpty { queue.append(token) }
            condition.signal()
        }
    }
    public func finish() { condition.withLock { closed = true; condition.broadcast() } }
    public func cancel() { fail(CLIError("Text stream cancelled", code: .cancelled)) }
    public func fail(_ error: Error) { condition.withLock { failure = error; closed = true; queue.removeAll(); readIndex = 0; condition.broadcast() } }
    func next(cancelled: () -> Bool) throws -> SpeechTextToken? {
        condition.lock(); defer { condition.unlock() }
        while readIndex == queue.count && !closed {
            if cancelled() { throw CLIError("Text stream cancelled", code: .cancelled) }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        if let failure { throw failure }
        guard readIndex < queue.count else { return nil }
        let value = queue[readIndex]; readIndex += 1
        if readIndex == queue.count { queue.removeAll(keepingCapacity: true); readIndex = 0 }
        return value
    }
}
