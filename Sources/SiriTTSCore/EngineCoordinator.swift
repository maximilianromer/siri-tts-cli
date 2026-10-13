import Foundation

public final class EngineCoordinator: @unchecked Sendable {
    public let siri: SiriEngine
    public let av: AVEngine

    public init(keepSiriActive: Bool = false) {
        siri = SiriEngine(keepActive: keepSiriActive)
        av = AVEngine()
    }

    public func render(
        _ options: SynthesisOptions,
        onPCMChunk: (@Sendable (Data) -> Void)? = nil
    ) throws -> (audio: RenderedAudio, fallbackFrom: EngineKind?) {
        if options.engine == .av, options.controls.hasPrivateControls {
            throw CLIError("Siri-specific controls cannot be applied by the AV engine", code: .usage)
        }
        switch options.engine {
        case .siri:
            return (try siri.synthesize(options, onPCMChunk: onPCMChunk), nil)
        case .av:
            return (try av.synthesize(options, onPCMChunk: onPCMChunk), nil)
        case .auto:
            do {
                return (try siri.synthesize(options, onPCMChunk: onPCMChunk), nil)
            } catch let siriError as CLIError {
                if options.controls.hasPrivateControls { throw siriError }
                guard [.daemonUnreachable, .noCompatibleEngine, .noAudio].contains(siriError.code)
                else { throw siriError }
                do {
                    return (try av.synthesize(options, onPCMChunk: onPCMChunk), .siri)
                } catch {
                    throw CLIError(
                        "No compatible engine succeeded. Siri: \(siriError.message). AV: \(error.localizedDescription)",
                        code: .noCompatibleEngine
                    )
                }
            }
        }
    }

    public func cancel() {
        siri.cancel()
        av.cancel()
    }
}
