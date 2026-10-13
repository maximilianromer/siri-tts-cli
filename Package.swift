// swift-tools-version: 6.2
import Foundation
import PackageDescription

private func macOSSDKPath() -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--sdk", "macosx", "--show-sdk-path"]
    process.standardOutput = pipe
    do {
        try process.run()
    } catch {
        fatalError("Unable to run xcrun: \(error)")
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("xcrun could not locate the macOS developer kit")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
        fatalError("xcrun returned an empty macOS developer kit path")
    }
    return path
}

let privateFrameworks = macOSSDKPath() + "/System/Library/PrivateFrameworks"
let privateInterfaces = "Sources/PrivateInterfaces"
let xcodePrivateInterfaces = "${SRCROOT}/Sources/PrivateInterfaces"
let cliInfoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/siri-tts/Info.plist").path

let package = Package(
    name: "siri-tts-cli",
    platforms: [.macOS("15.6")],
    products: [
        .executable(name: "siri-tts", targets: ["siri-tts"]),
        .library(name: "SiriTTSClient", targets: ["SiriTTSClient"]),
        .library(name: "SiriTTSCore", targets: ["SiriTTSCore"]),
    ],
    targets: [
        .target(name: "SiriTTSProtocol"),
        .target(name: "SiriTTSClient", dependencies: ["SiriTTSProtocol"]),
        .target(
            name: "SiriTTSCore",
            dependencies: ["SiriTTSProtocol"],
            swiftSettings: [
                .unsafeFlags([
                    // Keeps private implementation imports out of executable clients.
                    // SiriTTSProtocol remains a source-only package without unsafe flags.
                    "-enable-library-evolution",
                    "-I\(privateInterfaces)",
                    "-I\(xcodePrivateInterfaces)",
                    "-F\(privateFrameworks)",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", privateFrameworks,
                    "-Xlinker", "-weak_framework",
                    "-Xlinker", "SiriTTSService",
                ]),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(
            name: "siri-tts",
            dependencies: ["SiriTTSCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                // macOS 27 voice subscriptions require Bundle.main to identify
                // the caller, even for a standalone command-line executable.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist", "-Xlinker", cliInfoPlist,
                ]),
            ]
        ),
        .testTarget(
            name: "SiriTTSCoreTests",
            dependencies: ["SiriTTSCore"],
            swiftSettings: [
                .unsafeFlags([
                    "-I\(privateInterfaces)",
                    "-I\(xcodePrivateInterfaces)",
                    "-F\(privateFrameworks)",
                ]),
            ]
        ),
        .testTarget(
            name: "SiriTTSClientTests",
            dependencies: ["SiriTTSClient"]
        ),
    ]
)
