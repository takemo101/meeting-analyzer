// swift-tools-version:6.0
import PackageDescription

// scripts/build-native.sh の出力先（transcribe.cpp の C のヘッダと静的ライブラリ）。
let native = "\(Context.packageDirectory)/build/native"

let package = Package(
    name: "MeetingAnalyzer",
    // SpeechAnalyzer / SpeechTranscriber（オンデバイスの文字起こし）は macOS 26 以降。Apple silicon だけを対象にする（SPEC §2）。
    platforms: [.macOS("26.0")],
    targets: [
        // アプリの本体。規則（Core）・文字起こし・エージェント連携・OS との接点・CLI・UI を持つ。テストはここを対象にする。
        // 文字起こしの推論の実行環境 transcribe.cpp（C のヘッダ）。ヘッダと静的ライブラリは、scripts/build-native.sh が build/native に作る。
        .target(name: "CTranscribe", path: "Sources/CTranscribe", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-I", "\(native)/include"])]),
        .target(
            name: "MeetingAnalyzerKit", dependencies: ["CTranscribe"], path: "Sources/MeetingAnalyzerKit",
            linkerSettings: [
                // 静的ライブラリは、Objective-C の実行時情報（Metal）を落とさないよう、丸ごと取り込む（`-force_load`）。
                .unsafeFlags(["libtranscribe.a", "libggml.a", "libggml-cpu.a", "libggml-metal.a", "libggml-base.a"].flatMap { ["-Xlinker", "-force_load", "-Xlinker", "\(native)/lib/\($0)"] }),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"), .linkedFramework("Foundation"), .linkedFramework("Metal"), .linkedFramework("MetalKit"),
            ]),
        // 実行ファイル。起動するだけ。
        .executableTarget(name: "MeetingAnalyzer", dependencies: ["MeetingAnalyzerKit"], path: "Sources/MeetingAnalyzer"),
        // 取り込みの試作（実験用。製品の CLI ではない）。マイク・システム音声の認識の遅延と音量を測る。
        .executableTarget(name: "CaptureProbe", dependencies: ["MeetingAnalyzerKit"], path: "Sources/CaptureProbe"),
        .testTarget(name: "MeetingAnalyzerKitTests", dependencies: ["MeetingAnalyzerKit"], path: "Tests/MeetingAnalyzerKitTests"),
    ],
    swiftLanguageModes: [.v5]
)
