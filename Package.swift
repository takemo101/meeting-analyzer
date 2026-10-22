// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MeetingAnalyzer",
    // SpeechAnalyzer / SpeechTranscriber（オンデバイスの文字起こし）は macOS 26 以降。Apple silicon だけを対象にする（SPEC §2）。
    platforms: [.macOS("26.0")],
    targets: [
        // アプリの本体。規則（Core）・文字起こし・エージェント連携・OS との接点・CLI・UI を持つ。テストはここを対象にする。
        .target(name: "MeetingAnalyzerKit", path: "Sources/MeetingAnalyzerKit"),
        // 実行ファイル。起動するだけ。
        .executableTarget(name: "MeetingAnalyzer", dependencies: ["MeetingAnalyzerKit"], path: "Sources/MeetingAnalyzer"),
        // 取り込みの試作（実験用。製品の CLI ではない）。マイク・システム音声の認識の遅延と音量を測る。
        .executableTarget(name: "CaptureProbe", dependencies: ["MeetingAnalyzerKit"], path: "Sources/CaptureProbe"),
        .testTarget(name: "MeetingAnalyzerKitTests", dependencies: ["MeetingAnalyzerKit"], path: "Tests/MeetingAnalyzerKitTests"),
    ],
    swiftLanguageModes: [.v5]
)
