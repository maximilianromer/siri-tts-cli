import Foundation
public import SiriTTSProtocol

/// A lightweight client for a separately running `siri-tts serve` helper.
///
/// This module deliberately does not link Apple's private speech framework into
/// the host application. The helper owns that compatibility boundary and exposes
/// the repository's versioned local HTTP interface instead.
public struct SiriTTSClient: Sendable {
    public typealias SpeechControls = SiriTTSProtocol.SpeechControls
    public typealias AcousticControls = SiriTTSProtocol.AcousticControls
    public typealias ProsodyControls = SiriTTSProtocol.ProsodyControls
    public typealias VoiceGeneration = SiriTTSProtocol.VoiceGeneration
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var bearerToken: String?
        public var timeout: TimeInterval

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
            timeout: TimeInterval = 86_400,
            bearerToken: String? = nil
        ) {
            self.baseURL = baseURL
            self.timeout = timeout
            self.bearerToken = bearerToken
        }
    }

    public struct Voice: Codable, Equatable, Sendable {
        public let id: String
        public let object: String
        public let ownedBy: String
        public var assetKey: String? = nil
        public var language: String? = nil
        public var generation: String? = nil

        enum CodingKeys: String, CodingKey {
            case id, object, assetKey, language, generation
            case ownedBy = "owned_by"
        }
    }

    public enum AudioFormat: String, Codable, CaseIterable, Sendable {
        case wav
        case pcm
    }

    public struct SynthesisRequest: Equatable, Sendable {
        public var text: String
        public var voice: String
        public var format: AudioFormat
        public var speed: Double
        public var model: String
        public var controls: SpeechControls?
        public var pitch: Float?
        public var volume: Float?
        public var ssml: Bool

        public init(
            text: String,
            voice: String,
            format: AudioFormat = .wav,
            speed: Double = 1,
            model: String = "tts-1",
            controls: SpeechControls? = nil,
            pitch: Float? = nil,
            volume: Float? = nil,
            ssml: Bool = false
        ) {
            self.text = text
            self.voice = voice
            self.format = format
            self.speed = speed
            self.model = model
            self.controls = controls
            self.pitch = pitch
            self.volume = volume
            self.ssml = ssml
        }
    }

    public struct SynthesizedAudio: Equatable, Sendable {
        public let data: Data
        public let format: AudioFormat
        public let contentType: String
        public let engine: String?
        public var voice: ResolvedVoice? = nil

        public init(
            data: Data,
            format: AudioFormat,
            contentType: String,
            engine: String?
        ) {
            self.data = data
            self.format = format
            self.contentType = contentType
            self.engine = engine
        }
    }

    /// Metadata for audio saved without first loading the response into memory.
    public struct SynthesizedAudioFile: Equatable, Sendable {
        public let url: URL
        public let format: AudioFormat
        public let contentType: String
        public let engine: String?
        public var voice: ResolvedVoice? = nil
        public let byteCount: Int64

        public init(
            url: URL,
            format: AudioFormat,
            contentType: String,
            engine: String?,
            byteCount: Int64
        ) {
            self.url = url
            self.format = format
            self.contentType = contentType
            self.engine = engine
            self.byteCount = byteCount
        }
    }

    public struct ResolvedVoice: Equatable, Sendable {
        public let assetKey: String?
        public let verified: Bool?
        public let substituted: Bool?
        public let pace: String?
        public let expressivity: String?
        public let acoustics: String?
        public let clientID: String?
        public let unverifiedControls: [String]
        init(_ response: HTTPURLResponse) {
            assetKey = response.value(forHTTPHeaderField: "X-Siri-TTS-Voice")
            verified = response.value(forHTTPHeaderField: "X-Siri-TTS-Voice-Verified").flatMap(Bool.init)
            substituted = response.value(forHTTPHeaderField: "X-Siri-TTS-Voice-Substituted").flatMap(Bool.init)
            pace = response.value(forHTTPHeaderField: "X-Siri-TTS-Pace")
            expressivity = response.value(forHTTPHeaderField: "X-Siri-TTS-Expressivity")
            acoustics = response.value(forHTTPHeaderField: "X-Siri-TTS-Acoustics")
            clientID = response.value(forHTTPHeaderField: "X-Siri-TTS-Client-ID")
            unverifiedControls = (response.value(forHTTPHeaderField: "X-Siri-TTS-Unverified-Controls") ?? "").split(separator: ",").map(String.init)
        }
    }

    public enum ClientError: LocalizedError, Equatable, Sendable {
        case invalidConfiguration(String)
        case invalidResponse
        case server(statusCode: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .invalidConfiguration(let message):
                message
            case .invalidResponse:
                "The siri-tts helper returned an invalid HTTP response"
            case .server(let statusCode, let message):
                "siri-tts helper returned HTTP \(statusCode): \(message)"
            }
        }
    }

    private struct ModelsResponse: Decodable {
        let data: [Voice]
    }

    private struct ServerErrorResponse: Decodable {
        struct Detail: Decodable {
            let message: String
        }

        let error: Detail
    }

    private struct WireSynthesisRequest: Encodable {
        let model: String
        let input: String
        let voice: String
        let responseFormat: String
        let speed: Double
        var controls: SpeechControls?
        var pitch: Float?
        var volume: Float?
        var ssml: Bool

        enum CodingKeys: String, CodingKey {
            case model, input, voice, speed, controls, pitch, volume, ssml
            case responseFormat = "response_format"
        }
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias DownloadTransport = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    private let configuration: Configuration
    private let transport: Transport
    private let downloadTransport: DownloadTransport

    public init(
        configuration: Configuration = Configuration(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.transport = { request in
            try await session.data(for: request)
        }
        self.downloadTransport = { request in
            try await session.download(for: request)
        }
    }

    init(
        configuration: Configuration,
        transport: @escaping Transport,
        downloadTransport: @escaping DownloadTransport = { _ in
            throw ClientError.invalidResponse
        }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.downloadTransport = downloadTransport
    }

    public func capabilities() async throws -> CapabilityReport {
        let request = try makeRequest(path: ["v1", "capabilities"])
        let (data, response) = try await transport(request)
        _ = try validate(response, data: data)
        do { return try JSONDecoder().decode(CapabilityReport.self, from: data) }
        catch { throw ClientError.invalidResponse }
    }

    /// Legacy voices currently support all three native phoneme alphabets.
    public func phonemes(_ request: SynthesisRequest, alphabet: PhonemeAlphabet = .xsampa) async throws -> TextAnalysisResult {
        try await analyze(request, alphabet: alphabet)
    }
    public func estimateDuration(_ request: SynthesisRequest) async throws -> TextAnalysisResult {
        try await analyze(request, alphabet: nil)
    }
    private func analyze(_ request: SynthesisRequest, alphabet: PhonemeAlphabet?) async throws -> TextAnalysisResult {
        let speech = try makeSynthesisRequest(request)
        var wire = try makeRequest(path: ["v1", "audio", alphabet == nil ? "estimate" : "phonemes"])
        var body = try JSONSerialization.jsonObject(with: speech.httpBody!) as! [String: Any]
        if let alphabet { body["phonemeSystem"] = alphabet.rawValue }
        wire.httpMethod = "POST"; wire.setValue("application/json", forHTTPHeaderField: "Content-Type")
        wire.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport(wire)
        _ = try validate(response, data: data)
        do { return try JSONDecoder().decode(TextAnalysisResult.self, from: data) }
        catch { throw ClientError.invalidResponse }
    }

    public func manageVoice(_ action: VoiceActionRequest) async throws -> VoiceActionResult {
        var request = try makeRequest(path: ["v1", "voices", "actions"])
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(action)
        let (data, response) = try await transport(request); _ = try validate(response, data: data)
        do { return try JSONDecoder().decode(VoiceActionResult.self, from: data) } catch { throw ClientError.invalidResponse }
    }
    public func subscriptions() async throws -> [VoiceSubscriptionInfo] {
        let request = try makeRequest(path: ["v1", "subscriptions"])
        let (data, response) = try await transport(request); _ = try validate(response, data: data)
        do { return try JSONDecoder().decode([VoiceSubscriptionInfo].self, from: data) } catch { throw ClientError.invalidResponse }
    }
    public func presets(voice: String) async throws -> VoicePresetReport {
        var request = try makeRequest(path: ["v1", "voices", "presets"])
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["voice": voice])
        let (data, response) = try await transport(request); _ = try validate(response, data: data)
        do { return try JSONDecoder().decode(VoicePresetReport.self, from: data) } catch { throw ClientError.invalidResponse }
    }

    public func voices() async throws -> [Voice] {
        let request = try makeRequest(path: ["v1", "models"])
        let (data, response) = try await transport(request)
        let http = try validate(response, data: data)
        guard http.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains("application/json") == true else {
            throw ClientError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(ModelsResponse.self, from: data).data
        } catch {
            throw ClientError.invalidResponse
        }
    }

    public func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
        let urlRequest = try makeSynthesisRequest(request)
        let (data, response) = try await transport(urlRequest)
        let http = try validate(response, data: data)
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let expectedType = request.format == .wav ? "audio/wav" : "application/octet-stream"
        guard contentType.lowercased().contains(expectedType), !data.isEmpty else {
            throw ClientError.invalidResponse
        }
        var result = SynthesizedAudio(
            data: data,
            format: request.format,
            contentType: contentType,
            engine: http.value(forHTTPHeaderField: "X-Siri-TTS-Engine")
        )
        result.voice = ResolvedVoice(http)
        return result
    }

    /// Saves a response to disk without retaining the complete audio payload in memory.
    /// Prefer this method for books, articles, and other long input.
    public func synthesize(
        _ request: SynthesisRequest,
        to destination: URL
    ) async throws -> SynthesizedAudioFile {
        let urlRequest = try makeSynthesisRequest(request)
        let (downloadedURL, response) = try await downloadTransport(urlRequest)
        let http: HTTPURLResponse
        if let candidate = response as? HTTPURLResponse,
           !(200...299).contains(candidate.statusCode) {
            let errorData = (try? Data(contentsOf: downloadedURL)) ?? Data()
            _ = try validate(response, data: errorData)
            throw ClientError.invalidResponse
        } else {
            http = try validate(response, data: Data())
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let expectedType = request.format == .wav ? "audio/wav" : "application/octet-stream"
        let byteCount = try downloadedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard contentType.lowercased().contains(expectedType), byteCount > 0 else {
            throw ClientError.invalidResponse
        }
        try installDownloadedFile(downloadedURL, at: destination)
        var result = SynthesizedAudioFile(
            url: destination,
            format: request.format,
            contentType: contentType,
            engine: http.value(forHTTPHeaderField: "X-Siri-TTS-Engine"),
            byteCount: Int64(byteCount)
        )
        result.voice = ResolvedVoice(http)
        return result
    }

    private func makeSynthesisRequest(_ request: SynthesisRequest) throws -> URLRequest {
        try request.controls?.validate()
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.speed.isFinite, (0.25...4).contains(request.speed) else { throw ClientError.invalidConfiguration("Speech text and speed are invalid") }
        if let pitch = request.pitch, !pitch.isFinite || !(0.5...2).contains(pitch) { throw ClientError.invalidConfiguration("Invalid pitch") }
        if let volume = request.volume, !volume.isFinite || !(0...1).contains(volume) { throw ClientError.invalidConfiguration("Invalid volume") }
        let body = WireSynthesisRequest(
            model: request.model,
            input: request.text,
            voice: request.voice,
            responseFormat: request.format.rawValue,
            speed: request.speed,
            controls: request.controls,
            pitch: request.pitch,
            volume: request.volume,
            ssml: request.ssml
        )
        var urlRequest = try makeRequest(path: ["v1", "audio", "speech"])
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    private func installDownloadedFile(_ source: URL, at destination: URL) throws {
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        guard manager.fileExists(atPath: parent.path) else {
            throw ClientError.invalidConfiguration("The output folder does not exist")
        }
        let staging = parent.appendingPathComponent(
            ".siri-tts-download-\(UUID().uuidString)"
        )
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
    }

    private func makeRequest(path: [String]) throws -> URLRequest {
        guard let scheme = configuration.baseURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              configuration.baseURL.host != nil,
              configuration.timeout > 0 else {
            throw ClientError.invalidConfiguration(
                "The siri-tts helper URL and timeout are invalid"
            )
        }
        let url = path.reduce(configuration.baseURL) {
            $0.appendingPathComponent($1)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.timeout
        if let token = configuration.bearerToken {
            guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { throw ClientError.invalidConfiguration("Invalid bearer token") }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func validate(_ response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerErrorResponse.self, from: data))?
                .error.message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ClientError.server(statusCode: http.statusCode, message: message)
        }
        return http
    }
}
