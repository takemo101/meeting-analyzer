import Foundation

/// Qwen3 の decoder の形（`config.json` の値。固定した版のものを、ここに持つ）。
public struct QwenShape: Sendable, Equatable {
    public let hidden: Int
    public let layers: Int
    public let heads: Int
    public let kvHeads: Int
    public let headDim: Int
    public let intermediate: Int
    public let rmsEps: Float
    public let ropeTheta: Float
    /// 較正した温度（判断の頭の出力を割る）。
    public let temperature: Float

    public init(hidden: Int, layers: Int, heads: Int, kvHeads: Int, headDim: Int, intermediate: Int, rmsEps: Float, ropeTheta: Float, temperature: Float) {
        self.hidden = hidden
        self.layers = layers
        self.heads = heads
        self.kvHeads = kvHeads
        self.headDim = headDim
        self.intermediate = intermediate
        self.rmsEps = rmsEps
        self.ropeTheta = ropeTheta
        self.temperature = temperature
    }
}

/// 追加でダウンロードして使える、System One 型の判断モデル（SPEC §3.13）。閉じた選択肢に、確率（確信度）を返す。
/// 形が違う系統ごとに、実行の実装が要る（`architecture`）。いまは Qwen3 の decoder ＋ 判断の頭（Tiny-Jev）だけ。
public struct DecisionModel: Sendable, Equatable, Identifiable {
    public enum Architecture: Sendable, Equatable {
        /// Qwen3 の decoder の最終層の隠れ状態を、選択肢ごとの印（`<opt>`）の位置で読み、1 次元の頭で採点する（Tiny-Jev）。
        case qwenOptionMarker(QwenShape)
    }

    public let id: String
    public let name: String
    /// 選ぶときの説明（特徴・ライセンス）。
    public let summary: String
    public let weights: ModelArtifact
    public let tokenizer: ModelArtifact
    public let architecture: Architecture

    public init(id: String, name: String, summary: String, weights: ModelArtifact, tokenizer: ModelArtifact, architecture: Architecture) {
        self.id = id
        self.name = name
        self.summary = summary
        self.weights = weights
        self.tokenizer = tokenizer
        self.architecture = architecture
    }

    /// 取得するファイル（小さいものを先に）。
    public var artifacts: [ModelArtifact] { [tokenizer, weights] }
    public var bytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }
}

/// 使える判断モデルの一覧。**測定で使えると確かめたもの**だけ（SPEC §3.13・検証記録）。ライセンスが明確なもの。
public enum DecisionModelCatalog {
    public static let all: [DecisionModel] = [
        DecisionModel(
            id: "tiny-jev-0.6b", name: "Tiny-Jev 0.6B",
            summary: "Qwen3-0.6B を、確率つきの判断用に学習したモデル（Apache-2.0）。英語向けの学習だが、日本語でも動く。軽く、速い（1 問 約 20 ms）。",
            weights: ModelArtifact(
                repository: "lostargon/Tiny-Jev", revision: "62449fb3272d68fb8c8fe8a33082566643a76d0b", filename: "model.safetensors",
                bytes: 1_191_594_564, sha256: "513411b17cb0eca54839ca3948b4353e7f65710723ffcde8d13e3cb04328633e"),
            tokenizer: ModelArtifact(
                repository: "lostargon/Tiny-Jev", revision: "62449fb3272d68fb8c8fe8a33082566643a76d0b", filename: "tokenizer.json",
                bytes: 11_422_832, sha256: "e3fccc77adda606e2a461ffd17ca5a55a5a75ac40a5aa0a91c5307fb31b1efac"),
            architecture: .qwenOptionMarker(QwenShape(hidden: 1024, layers: 28, heads: 16, kvHeads: 8, headDim: 128, intermediate: 3072, rmsEps: 1e-6, ropeTheta: 1_000_000, temperature: 0.95))
        ),
    ]

    public static func model(id: String) -> DecisionModel? { all.first { $0.id == id } }
}
