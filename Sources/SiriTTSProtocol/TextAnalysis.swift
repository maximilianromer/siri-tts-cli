import Foundation

public enum PhonemeAlphabet: String, Codable, CaseIterable, Sendable {
    case nashville, xsampa, lhp
}

public struct TextAnalysisResult: Codable, Equatable, Sendable {
    public let operation: String
    public let requestedVoice: String
    public let text: String
    public let phonemeSystem: PhonemeAlphabet?
    public let phonemes: String?
    public let estimatedSeconds: Double?
    public let warnings: [String]
    public init(operation: String, requestedVoice: String, text: String, phonemeSystem: PhonemeAlphabet? = nil,
                phonemes: String? = nil, estimatedSeconds: Double? = nil, warnings: [String] = []) {
        self.operation = operation; self.requestedVoice = requestedVoice; self.text = text
        self.phonemeSystem = phonemeSystem; self.phonemes = phonemes
        self.estimatedSeconds = estimatedSeconds; self.warnings = warnings
    }
}
