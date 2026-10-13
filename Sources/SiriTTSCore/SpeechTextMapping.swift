import Foundation

/// The native plain-text frontend can collapse blank lines before reporting
/// ranges. Submit canonical whitespace and retain a UTF-16 map to the caller's
/// original text, so paragraph breaks cannot accumulate offset drift.
struct SpeechTextMapping {
    let text: String
    private let sourceOffsets: [Int]

    init(_ source: String) {
        var text = ""
        var offsets: [Int] = []
        var sourceOffset = 0
        var whitespaceStart: Int?
        var hasNewline = false
        for character in source {
            let count = character.utf16.count
            if character.isWhitespace {
                if whitespaceStart == nil { whitespaceStart = sourceOffset }
                hasNewline = hasNewline || character.isNewline
            } else {
                if let whitespaceStart, !text.isEmpty {
                    text.append(hasNewline ? "\n" : " ")
                    offsets.append(whitespaceStart)
                }
                whitespaceStart = nil
                hasNewline = false
                text.append(character)
                offsets.append(contentsOf: sourceOffset..<(sourceOffset + count))
            }
            sourceOffset += count
        }
        self.text = text
        self.sourceOffsets = offsets
    }

    func restore(_ timing: RawWordTiming) -> RawWordTiming? {
        let range = timing.range
        let (end, overflow) = range.location.addingReportingOverflow(range.length)
        guard !overflow, range.location >= 0, range.length > 0,
              end <= sourceOffsets.count else { return nil }
        let location = sourceOffsets[range.location]
        return RawWordTiming(start: timing.start, range: NSRange(
            location: location, length: sourceOffsets[end - 1] + 1 - location
        ))
    }
}
