import FluidAudio
import Foundation

/// 分離の結果：区間（秒。`samples` の先頭が 0。`speaker` は、会議ごとの、意味のない文字列）と、話者ごとの声の特徴（埋め込み。無い話者もある）。
public struct VoiceSeparation: Sendable, Equatable {
    public let segments: [VoiceSegment]
    public let embeddings: [String: [Float]]

    public init(segments: [VoiceSegment], embeddings: [String: [Float]] = [:]) {
        self.segments = segments
        self.embeddings = embeddings
    }
}

/// 会議の音声（16 kHz・モノラル）を、声の違いで分ける（SPEC §3.14）。実機は `FluidVoiceSeparator`、テストは偽物。
public protocol VoiceSeparating: Sendable {
    func separate(_ samples: [Float]) async throws -> VoiceSeparation
}

public enum VoiceSeparationError: Error, Sendable, Equatable {
    /// モデルが取得されていない・検証に通らない。
    case modelUnavailable
    /// 読み込み・分離に失敗した。
    case failed(String)

    public var message: String {
        switch self {
        case .modelUnavailable: return "話者の分離のモデルが、取得されていません（取得済みでも、検証に通りませんでした）"
        case .failed(let reason): return "話者の分離に失敗しました（\(reason)）"
        }
    }
}

/// 分離の調整（SPEC §3.14）。無指定（`nil`）は、自動（FluidAudio の既定）。
public struct VoiceSeparationTuning: Sendable, Equatable {
    /// 話者の人数（分かっているとき）。2〜8。無指定は、自動。声の似た人が 1 つにまとまるとき、人数を指定すると、その数に分ける。
    public var speakerCount: Int?

    public static let speakerCountRange = 2...8

    public init(speakerCount: Int? = nil) {
        self.speakerCount = speakerCount
    }
}

/// FluidAudio のオフライン方式（話者の区間の検出・埋め込み・クラスタリング）。**このファイルだけが、FluidAudio を使う**。
/// モデルは、**取得済み・検証済みのフォルダ**（`ModelStore.folder`）から読み込む。**FluidAudio の通信は止める**（`ModelHub.offlineMode`）。
/// 会議の終了のときに 1 回だけ読み込み、分離したら、解放する（会議が実行中でないとき、メモリ・CPU を使わない）。
public struct FluidVoiceSeparator: VoiceSeparating {
    private let model: VoiceModel
    private let store: ModelStore
    private let tuning: VoiceSeparationTuning

    public init(model: VoiceModel, store: ModelStore, tuning: VoiceSeparationTuning = VoiceSeparationTuning()) {
        self.model = model
        self.store = store
        self.tuning = tuning
    }

    public func separate(_ samples: [Float]) async throws -> VoiceSeparation {
        guard store.ensureVerified(model) else { throw VoiceSeparationError.modelUnavailable }
        ModelHub.offlineMode = true
        // FluidAudio の記録は、端末（標準エラー）へ出さない（失敗は、こちらが、1 つの文で伝える。環境の情報・処理の細部の行も、出さない）。
        AppLogger.mirrorsToConsole = false
        AppLogger.minimumLevel = .error
        writeRevisionMarker()
        do {
            // `prepareModels` は、読み込みに失敗すると、フォルダを**消して**、取り直そうとする（通信は止めてあるので、取り直せない）。検証済みのファイルを消されないよう、直接読み込む。
            let models = try await OfflineDiarizerModels.load(from: store.folder(model))
            var config = OfflineDiarizerConfig()
            if let count = tuning.speakerCount { config.clustering.numSpeakers = count }
            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: models)
            let result = try await manager.process(audio: samples)
            return VoiceSeparation(
                segments: result.segments.map { VoiceSegment(speaker: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds)) },
                embeddings: result.speakerDatabase ?? [:]
            )
        } catch {
            throw VoiceSeparationError.failed(String(describing: error))
        }
    }

    /// FluidAudio は、固定した版の印（`.fluidaudio-revision`）が、フォルダに無いと、「取得し直し」の扱いにする（通信は止めてあるので、読み込みに失敗する）。
    /// 検証済みのファイルがそろっているので、版を書く（FluidAudio が固定している版と、同じ版のファイルだけを、取得している）。
    private func writeRevisionMarker() {
        let marker = store.folder(model).appendingPathComponent(VoiceModel.folderName(of: model.repository), isDirectory: true).appendingPathComponent(".fluidaudio-revision")
        guard (try? String(contentsOf: marker, encoding: .utf8)) != model.revision else { return }
        try? model.revision.write(to: marker, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }
}
