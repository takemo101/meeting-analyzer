import Foundation

/// モデル 1 つを使えるようにするための、取得物の並びと、取り方（SPEC §3.12・§3.13）。メニュー（`MeetingController`）と CLI（`models download`）が、同じ手順を使う。
/// - `quiet`：進み具合に含めない、小さな補助（文字起こしのモデルの、音声区間の検出のモデル）。先に取る。
/// - `reported`：進み具合に含める取得物。順に取り、（取得済み、全体）を、**全体の合計に対して**報告する（判断モデルは、トークナイザ → 重み）。
public struct ModelInstallPlan: Sendable {
    public let quiet: [ModelArtifact]
    public let reported: [ModelArtifact]

    /// 1 つの取得物を取る関数。`progress`：（その取得物の取得済み、その取得物の全体）のバイト数。実機は `ModelDownloader.download`、試験は偽物。
    public typealias Fetch = @Sendable (ModelArtifact, @escaping @Sendable (Int64, Int64) -> Void) async throws -> Void

    public init(quiet: [ModelArtifact] = [], reported: [ModelArtifact]) {
        self.quiet = quiet
        self.reported = reported
    }

    /// 文字起こしのモデル：音声区間の検出のモデル（小さい）→ 本体。進み具合は、本体だけ。
    public init(_ model: LocalModel) {
        self.init(quiet: [LocalModelCatalog.voiceActivity], reported: [model.artifact])
    }

    /// 判断モデル：トークナイザ → 重み。進み具合は、2 つの合計。
    public init(_ model: DecisionModel) {
        self.init(reported: model.artifacts)
    }

    /// 声の分離のモデル：複数のファイルを、小さいものから順に。進み具合は、全体の合計。
    public init(_ model: VoiceModel) {
        self.init(reported: model.artifacts.sorted { $0.bytes < $1.bytes })
    }

    /// 進み具合の全体（バイト数）。
    public var total: Int64 { reported.reduce(0) { $0 + $1.bytes } }

    /// 順に取る。途中で失敗・取り消しがあれば、そこで投げる（取得済みの分は、各取得の仕組みが残す）。
    public func run(fetch: Fetch, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        for artifact in quiet { try await fetch(artifact) { _, _ in } }
        let total = self.total
        var finished: Int64 = 0
        for artifact in reported {
            let base = finished
            try await fetch(artifact) { received, _ in progress(base + received, total) }
            finished += artifact.bytes
        }
    }
}
