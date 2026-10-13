import Foundation

/// Reads bounded records without loading a whole batch or pipe into memory.
struct JSONLineReader {
    let handle: FileHandle
    var buffer = Data()
    var ended = false
    let maximumLineBytes: Int
    init(handle: FileHandle, maximumLineBytes: Int = 1_048_576) { self.handle = handle; self.maximumLineBytes = maximumLineBytes }
    mutating func next() throws -> Data? {
        while true {
            if let index = buffer.firstIndex(of: 10) {
                guard index <= maximumLineBytes else { throw CLIError("JSONL record exceeds its byte limit", code: .usage) }
                let line = Data(buffer[..<index]); buffer.removeSubrange(...index)
                if line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { continue }
                return line
            }
            guard buffer.count <= maximumLineBytes else { throw CLIError("JSONL record exceeds its byte limit", code: .usage) }
            if ended { defer { buffer.removeAll() }; return buffer.isEmpty ? nil : buffer }
            let chunk = try handle.read(upToCount: 8192) ?? Data()
            if chunk.isEmpty { ended = true } else { buffer.append(chunk) }
        }
    }
}
