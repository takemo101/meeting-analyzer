import Foundation

/// 追加でダウンロードして使える、声による話者の分離のモデル（SPEC §3.14）。
/// 1 つのモデルは、**複数のファイル**（Core ML の `.mlmodelc` が、ディレクトリ）。**すべてのファイルが、そろってはじめて「取得済み」**。
/// 保管は、`models/voice/<版の先頭 12 桁>/<リポジトリの名前>/…`（FluidAudio が、読み込むときの並びと同じ。FluidAudio 自身の取得は、使わない）。
public struct VoiceModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// 選ぶときの説明（特徴・ライセンス）。
    public let summary: String
    public let repository: String
    public let revision: String
    public let artifacts: [ModelArtifact]

    public init(id: String, name: String, summary: String, repository: String, revision: String, files: [(path: String, bytes: Int64, sha256: String)]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.repository = repository
        self.revision = revision
        let folder = "voice/\(revision.prefix(12))/\(repository.split(separator: "/").last.map(String.init) ?? repository)"
        self.artifacts = files.map {
            ModelArtifact(repository: repository, revision: revision, filename: $0.path, bytes: $0.bytes, sha256: $0.sha256, storedAs: "\(folder)/\($0.path)")
        }
    }

    public static func == (lhs: VoiceModel, rhs: VoiceModel) -> Bool {
        lhs.id == rhs.id && lhs.revision == rhs.revision && lhs.artifacts == rhs.artifacts
    }

    public var bytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }

    /// FluidAudio の `OfflineDiarizerModels.load(from:)` へ渡すディレクトリ（この下に、`<リポジトリの名前>/` がある）。
    public var storageFolder: String { "voice/\(revision.prefix(12))" }
}

/// 使える、声の分離のモデルの一覧。**測定で使えると確かめたもの**だけ（検証記録 2026-10-31・2026-11-01）。
/// pyannote の speaker-diarization-community-1（CC-BY-4.0）を、FluidInference が Core ML へ変換したもの。**利用者に見える表示・同梱するライセンスに、出典（pyannote・WeSpeaker・BUT Speech@FIT・FluidInference）と、CC-BY-4.0・改変（Core ML への変換）を示す**（SPEC §3.14）。
public enum VoiceModelCatalog {
    public static let all: [VoiceModel] = [
        VoiceModel(
            id: "speaker-separation",
            name: "話者の分離（pyannote community-1）",
            summary: "声の違いで、相手の話者を分ける（約 22 MB）。CC-BY-4.0。",
            repository: "FluidInference/speaker-diarization-coreml",
            revision: "df2625ac79a7ac6b65ad868fee6d80f320da4232",
            files: [
                ("Embedding.mlmodelc/analytics/coremldata.bin", 243, "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"),
                ("Embedding.mlmodelc/coremldata.bin", 704, "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"),
                ("Embedding.mlmodelc/metadata.json", 2_818, "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5"),
                ("Embedding.mlmodelc/model.mil", 78_432, "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3"),
                ("Embedding.mlmodelc/weights/weight.bin", 13_412_288, "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"),
                ("FBank.mlmodelc/analytics/coremldata.bin", 243, "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"),
                ("FBank.mlmodelc/coremldata.bin", 853, "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"),
                ("FBank.mlmodelc/metadata.json", 3_409, "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a"),
                ("FBank.mlmodelc/model.mil", 15_667, "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed"),
                ("FBank.mlmodelc/weights/weight.bin", 1_776_896, "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"),
                ("PldaRho.mlmodelc/analytics/coremldata.bin", 243, "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7"),
                ("PldaRho.mlmodelc/coremldata.bin", 763, "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418"),
                ("PldaRho.mlmodelc/metadata.json", 2_749, "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945"),
                ("PldaRho.mlmodelc/model.mil", 7_613, "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041"),
                ("PldaRho.mlmodelc/weights/weight.bin", 200_192, "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"),
                ("Segmentation.mlmodelc/analytics/coremldata.bin", 243, "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"),
                ("Segmentation.mlmodelc/coremldata.bin", 812, "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"),
                ("Segmentation.mlmodelc/metadata.json", 3_410, "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124"),
                ("Segmentation.mlmodelc/model.mil", 43_063, "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f"),
                ("Segmentation.mlmodelc/weights/weight.bin", 5_959_360, "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"),
                ("plda-parameters.json", 89_416, "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"),
            ]
        ),
    ]

    public static func model(id: String) -> VoiceModel? { all.first { $0.id == id } }
}
