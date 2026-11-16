// swift-tools-version: 6.2
// FlowIQ package layout: docs/ARCHITEKTUR.md, appendix E.1. No unsafe compiler flags, no third-party packages.
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .treatAllWarnings(as: .error),
]

func library(_ name: String, _ dependencies: [Target.Dependency] = []) -> Target {
    .target(name: name, dependencies: dependencies, swiftSettings: strict)
}

func tests(_ name: String, _ dependencies: [Target.Dependency] = []) -> Target {
    .testTarget(name: name, dependencies: dependencies, swiftSettings: strict)
}

let core: Target.Dependency = "FlowIQCore"
let log: Target.Dependency = "FlowIQLog"

let package = Package(
    name: "FlowIQ",
    platforms: [.macOS("26.0")],
    targets: [
        library("FlowIQCore"),
        library("FlowIQLog", [core]),
        library("FlowIQInput", [core, log]),
        library("FlowIQAudio", [core, log]),
        library("FlowIQRecording", [core, log, "FlowIQAudio"]),
        library("FlowIQSpeech", [core, log, "FlowIQAudio", "FlowIQText"]),  // Recognition is the output (A.6)
        library("FlowIQText", [core]),
        library("FlowIQInsert", [core, log]),
        library("FlowIQStore", [core, log, "FlowIQText", "FlowIQRecording"]),  // size check before the archive (A.5)
        library("FlowIQCloud", [core, log]),
        library("FlowIQDevices", [core, log]),
        .executableTarget(
            name: "FlowIQ",
            dependencies: [core, log, "FlowIQInput", "FlowIQAudio", "FlowIQRecording", "FlowIQSpeech",
                           "FlowIQText", "FlowIQInsert", "FlowIQStore", "FlowIQCloud", "FlowIQDevices"],
            swiftSettings: strict + [.defaultIsolation(MainActor.self)]),
        .executableTarget(
            name: "flowiq-tool",
            dependencies: [core, log, "FlowIQText", "FlowIQStore", "FlowIQAudio", "FlowIQSpeech", "FlowIQCloud"],
            path: "Sources/FlowIQTool",
            swiftSettings: strict),
        tests("FlowIQCoreTests", [core]),
        tests("FlowIQLogTests", [core, log]),
        tests("BuildScriptTests"),
        tests("FlowIQAudioTests", [core, log, "FlowIQAudio"]),
        tests("FlowIQRecordingTests", [core, log, "FlowIQAudio", "FlowIQRecording"]),
        // P3 acceptance tests, bound by path (written before the code, expected values unchangeable).
        .testTarget(name: "FlowIQP3Tests", dependencies: [core, log, "FlowIQAudio", "FlowIQRecording"],
                    path: "abnahme-tests/p3", exclude: ["README.md"], swiftSettings: strict),
        tests("FlowIQTextTests", ["FlowIQText"]),
        tests("FlowIQStoreTests", [core, log, "FlowIQText", "FlowIQStore"]),
        tests("FlowIQAppTests", [core, "FlowIQCloud", "FlowIQRecording", "FlowIQStore", "FlowIQ"]),  // P7 views
        tests("FlowIQCloudTests", [core, log, "FlowIQCloud"]),
        tests("FlowIQDevicesTests", [core, log, "FlowIQDevices"]),
        tests("FlowIQInsertTests", [core, log, "FlowIQInsert"]),
        tests("FlowIQToolTests", ["flowiq-tool"]),
        tests("FlowIQSpeechTests", ["FlowIQSpeech", "FlowIQAudio", "FlowIQText"]),
        // P2 acceptance tests, bound by path (written before the code, expected values unchangeable).
        .testTarget(name: "FlowIQP2Tests", dependencies: ["FlowIQText"], path: "abnahme-tests/p2",
                    exclude: ["README.md"], swiftSettings: strict),
        // P4 acceptance tests, bound by path (written before the code, expected values unchangeable).
        .testTarget(name: "FlowIQP4Tests",
                    dependencies: [core, log, "FlowIQAudio", "FlowIQRecording", "FlowIQInput", "FlowIQInsert",
                                   "FlowIQSpeech", "FlowIQStore", "FlowIQText", "FlowIQ"],
                    path: "abnahme-tests/p4", exclude: ["README.md"], swiftSettings: strict),
        // P4 acceptance tests, version 3 additions (correction window, replace in the field, learning, raw version,
        // journal). DictationStaysLocalTests needs CloudPolicy and CallLiveFeed (P5) and joins with them.
        .testTarget(name: "FlowIQP4F3Tests",
                    dependencies: [core, log, "FlowIQAudio", "FlowIQInsert", "FlowIQSpeech", "FlowIQStore",
                                   "FlowIQText", "FlowIQCloud", "FlowIQ"],
                    path: "abnahme-tests/p4-f3", exclude: ["README.md"],
                    swiftSettings: strict),
        // P5 acceptance tests and their version 3 additions, bound by path (expected values unchangeable).
        .testTarget(name: "FlowIQP5Tests", dependencies: [core, log, "FlowIQStore", "FlowIQCloud"],
                    path: "abnahme-tests/p5", exclude: ["README.md"], swiftSettings: strict),
        // Scenario acceptance tests (Sonnet, from the description; expected values unchangeable).
        .testTarget(name: "FlowIQSzenarienTests",
                    dependencies: [core, log, "FlowIQAudio", "FlowIQRecording", "FlowIQInput", "FlowIQInsert",
                                   "FlowIQSpeech", "FlowIQStore", "FlowIQText", "FlowIQDevices", "FlowIQCloud",
                                   "FlowIQ"],
                    path: "abnahme-tests/szenarien", exclude: ["README.md"], swiftSettings: strict),
        .testTarget(name: "FlowIQP5F3Tests",
                    dependencies: [core, log, "FlowIQAudio", "FlowIQSpeech", "FlowIQStore", "FlowIQText",
                                   "FlowIQCloud"],
                    path: "abnahme-tests/p5-f3", exclude: ["README.md"], swiftSettings: strict),
    ]
)
