// swift-tools-version:6.2
import PackageDescription

// scripts/build-native.sh の出力先（transcribe.cpp の C のヘッダと静的ライブラリ）。
let native = "\(Context.packageDirectory)/build/native"

let package = Package(
    name: "MeetingAnalyzer",
    // SpeechAnalyzer / SpeechTranscriber（オンデバイスの文字起こし）は macOS 26 以降。Apple silicon だけを対象にする（SPEC §2）。
    platforms: [.macOS("26.0")],
    dependencies: [
        // 声による話者の分離（SPEC §3.14）。固定した版を取り込む。**Diarizer の機能だけ**（音声合成・テキスト正規化の約 87 MB のバイナリは、取り込まない）。モデルは、自分で取得・検証して読み込ませる（`ModelHub.offlineMode`）。
        .package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "16d0a17471f3da6083b44aaea4c07d1989239140", traits: ["Diarizer"]),
    ],
    targets: [
        // アプリの本体。規則（Core）・文字起こし・エージェント連携・OS との接点・CLI・UI を持つ。テストはここを対象にする。
        // 文字起こしの推論の実行環境 transcribe.cpp（C のヘッダ）。ヘッダと静的ライブラリは、scripts/build-native.sh が build/native に作る。
        .target(name: "CTranscribe", path: "Sources/CTranscribe", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-I", "\(native)/include"])]),
        .target(
            name: "MeetingAnalyzerKit", dependencies: ["CTranscribe", .product(name: "FluidAudio", package: "FluidAudio")], path: "Sources/MeetingAnalyzerKit",
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
