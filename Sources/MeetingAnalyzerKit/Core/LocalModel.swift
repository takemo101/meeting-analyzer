import Foundation

/// ダウンロードする 1 つのファイル（GGUF のモデル）。**リポジトリ・版（commit）・ファイル名・バイト数・SHA-256 を固定**する。
/// 版を固定するのは、同じ名前のファイルが、あとから入れ替わっても、検証に通らないようにするため（SPEC §3.12）。
public struct ModelArtifact: Sendable, Equatable {
    public let repository: String
    public let revision: String
    public let filename: String
    public let bytes: Int64
    public let sha256: String

    public init(repository: String, revision: String, filename: String, bytes: Int64, sha256: String) {
        self.repository = repository
        self.revision = revision
        self.filename = filename
        self.bytes = bytes
        self.sha256 = sha256
    }

    /// Hugging Face の、版を固定した取得先。
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")!
    }
}

/// 追加でダウンロードして使える、文字起こしのモデル（SPEC §3.12）。
public struct LocalModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// 選ぶときの説明（特徴・ライセンス）。
    public let summary: String
    public let artifact: ModelArtifact

    public init(id: String, name: String, summary: String, artifact: ModelArtifact) {
        self.id = id
        self.name = name
        self.summary = summary
        self.artifact = artifact
    }
}

/// 使えるモデルの一覧。ライセンスが明確なものだけ（Whisper：MIT、Qwen3-ASR：Apache-2.0）。
/// モデルは `handy-computer`（transcribe.cpp の作者）が、GGUF へ変換して公開しているもの（Q8_0）。
public enum LocalModelCatalog {
    public static let all: [LocalModel] = [
        LocalModel(
            id: "whisper-large-v3-turbo", name: "Whisper large-v3-turbo",
            summary: "雑音や専門用語に強い傾向。MIT ライセンス。",
            artifact: ModelArtifact(
                repository: "handy-computer/whisper-large-v3-turbo-gguf", revision: "d222c9f621c1128299248f2ded4d8a1820519780",
                filename: "whisper-large-v3-turbo-Q8_0.gguf", bytes: 886_381_824,
                sha256: "d5e65f2b0828802ae2c231673d31982cebe3a778c95d9494a9f3efee6bd17448")
        ),
        LocalModel(
            id: "qwen3-asr-0.6b", name: "Qwen3-ASR 0.6B",
            summary: "軽くて速い。Apache-2.0 ライセンス。",
            artifact: ModelArtifact(
                repository: "handy-computer/Qwen3-ASR-0.6B-gguf", revision: "e4e16599b900eb0cb36e524514756bb92eb092b7",
                filename: "Qwen3-ASR-0.6B-Q8_0.gguf", bytes: 850_423_456,
                sha256: "f081b2d5e23bd669d92cc331d722a8a0681943b8e6f34b48996fd5c319b5acd8")
        ),
        LocalModel(
            id: "qwen3-asr-1.7b", name: "Qwen3-ASR 1.7B",
            summary: "精度重視（大きく、少し遅い）。Apache-2.0 ライセンス。",
            artifact: ModelArtifact(
                repository: "handy-computer/Qwen3-ASR-1.7B-gguf", revision: "0e0a596e3959c3f3f2ab7d443a5b6f0f4a4bba6f",
                filename: "Qwen3-ASR-1.7B-Q8_0.gguf", bytes: 2_185_030_624,
                sha256: "9a0d81792dfea2d5f278b8a63deb3ea6e02139ce42c2301f32ea19c4f77526b7")
        ),
    ]

    /// 発話の区切りに使う、音声区間の検出のモデル（Silero VAD v6.2。MIT）。ローカルのモデルを使うとき、一緒に取得する。
    public static let voiceActivity = ModelArtifact(
        repository: "handy-computer/silero-vad-v6.2-gguf", revision: "a9b2d61c20ae4ddf3644edb34969e8185a485448",
        filename: "silero-vad-v6.2-F32.gguf", bytes: 1_241_056,
        sha256: "0d871a800c420fdd5d1b17a3aea4296d1c39608f0ff4a9295eb76457eb1c88e6")

    public static func model(id: String) -> LocalModel? { all.first { $0.id == id } }
}

/// 使う文字起こし。Mac 標準（既定）か、ダウンロードしたモデル。
public enum TranscriptionChoice: Sendable, Hashable {
    case apple
    case local(String)

    /// 保存・CLI で使う名前。`apple`、またはモデルの ID。
    public var id: String {
        switch self {
        case .apple: return "apple"
        case .local(let id): return id
        }
    }

    /// 名前から選択を作る。知らないモデルの ID は、`nil`。
    public init?(id: String) {
        if id == "apple" { self = .apple }
        else if LocalModelCatalog.model(id: id) != nil { self = .local(id) }
        else { return nil }
    }

    public var title: String {
        switch self {
        case .apple: return "Mac 標準"
        case .local(let id): return LocalModelCatalog.model(id: id)?.name ?? id
        }
    }
}
