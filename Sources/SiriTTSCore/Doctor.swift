import Darwin
import Foundation

public struct DoctorReport: Codable, Sendable {
    public let schemaVersion: Int
    public let toolVersion: String
    public let generatedAt: String
    public let system: SystemReport
    public let frameworkAvailable: Bool
    public let daemonReachable: Bool
    public let engines: [EngineReport]
    public let siriVoices: [VoiceDoctorReport]
    public let probe: ProbeReport?
    public let compatibility: String
}

public struct SystemReport: Codable, Sendable {
    public let productVersion: String
    public let buildVersion: String
    public let architecture: String
}

public struct EngineReport: Codable, Sendable {
    public let name: String
    public let available: Bool
    public let detail: String
}

public struct VoiceDoctorReport: Codable, Sendable {
    public let voice: VoiceInfo
    public let aneModelCompiled: Bool?
}

public struct ProbeReport: Codable, Sendable {
    public let succeeded: Bool
    public let engine: String?
    public let voice: String?
    public let sampleRate: Double?
    public let channels: Int?
    public let durationSeconds: Double?
    public let nonSilent: Bool?
    public let error: String?
}

public enum Doctor {
    public static func run(
        options: DoctorOptions,
        coordinator: EngineCoordinator
    ) -> DoctorReport {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let productVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let build = shellValue("/usr/bin/sw_vers", arguments: ["-buildVersion"]) ?? "unknown"
        var machine = utsname()
        uname(&machine)
        let architecture = withUnsafePointer(to: &machine.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }

        let frameworkAvailable = coordinator.siri.isFrameworkPresent
        let siriVoices: [VoiceInfo]
        let daemonReachable: Bool
        let siriDetail: String
        do {
            siriVoices = try coordinator.siri.voices()
            daemonReachable = true
            siriDetail = "\(siriVoices.count) installed voice(s)"
        } catch {
            siriVoices = []
            daemonReachable = false
            siriDetail = error.localizedDescription
        }
        let avVoices = coordinator.av.voices()
        let engines = [
            EngineReport(name: "siri", available: daemonReachable && !siriVoices.isEmpty, detail: siriDetail),
            EngineReport(name: "av", available: !avVoices.isEmpty, detail: "\(avVoices.count) public voice(s)"),
        ]
        let voiceReports = siriVoices.map {
            VoiceDoctorReport(
                voice: $0,
                aneModelCompiled: coordinator.siri.isANECompiled(voiceName: $0.assetKey)
            )
        }

        var probe: ProbeReport?
        if !options.skipProbe {
            var synthesis = SynthesisOptions()
            synthesis.text = "Siri Voice diagnostic \(UUID().uuidString.prefix(8))."
            synthesis.engine = daemonReachable ? .siri : .av
            synthesis.prewarm = true
            synthesis.timeout = 45
            do {
                let result = try coordinator.render(synthesis).audio
                let acceptance = try AudioIO.validatePCM(
                    result.pcm,
                    spec: result.spec,
                    text: synthesis.text
                )
                probe = ProbeReport(
                    succeeded: true,
                    engine: result.engine.rawValue,
                    voice: result.voice.name,
                    sampleRate: result.spec.sampleRate,
                    channels: result.spec.channels,
                    durationSeconds: acceptance.durationSeconds,
                    nonSilent: acceptance.nonSilent,
                    error: nil
                )
            } catch {
                probe = ProbeReport(
                    succeeded: false,
                    engine: nil,
                    voice: nil,
                    sampleRate: nil,
                    channels: nil,
                    durationSeconds: nil,
                    nonSilent: nil,
                    error: error.localizedDescription
                )
            }
        }
        let compatibility = (probe?.succeeded == true && daemonReachable)
            ? "verified-by-live-probe"
            : "unverified"

        return DoctorReport(
            schemaVersion: siriTTSSchemaVersion,
            toolVersion: siriTTSVersion,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            system: SystemReport(
                productVersion: productVersion,
                buildVersion: build,
                architecture: architecture
            ),
            frameworkAvailable: frameworkAvailable,
            daemonReachable: daemonReachable,
            engines: engines,
            siriVoices: voiceReports,
            probe: probe,
            compatibility: compatibility
        )
    }

    private static func shellValue(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
