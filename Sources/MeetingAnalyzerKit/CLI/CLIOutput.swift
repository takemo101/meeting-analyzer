import Foundation

/// パイプ向けの出力（機械が読む JSON。1 行 1 件）の形。キーの名前と、省略するキーは、SPEC §3.9 の契約。端末向けの見せ方は `CLIView`。
/// `JSONEncoder`（`.sortedKeys`・`.withoutEscapingSlashes`）で、キーを並べ替えて出す。値が `nil` のキーは、出さない。
enum CLIOutput {
    /// 失敗（標準エラー）。
    struct Failure: Encodable {
        var ok = false
        let code: String
        let message: String
    }

    struct Doctor: Encodable {
        let locale: String
        let supported: Bool
        let installed: Bool
    }

    /// `models` の一覧の 1 件。`kind` は、`transcription`（文字起こし）か `decision`（話者の推定）。
    struct ModelLine: Encodable {
        let kind: String
        let id: String
        let name: String
        let bytes: Int64
        let installed: Bool
        let downloadedBytes: Int64
    }

    /// `models download` の結果。
    struct Downloaded: Encodable {
        var ok = true
        let id: String
        let path: String
    }

    /// `models delete` の結果。
    struct Deleted: Encodable {
        var ok = true
        let id: String
        var deleted = true
    }

    struct PresetLine: Encodable {
        let id: String
        let name: String
        let source: String
        let description: String
    }

    /// 読めなかったプリセットのファイル。
    struct SkippedPreset: Encodable {
        let skipped: String
        let reason: String
    }

    struct ActorLine: Encodable {
        let name: String
        let aliases: [String]
        let topics: [String]
        let isSelf: Bool
        let role: String?

        private enum CodingKeys: String, CodingKey {
            case name, aliases, topics, role
            case isSelf = "self"
        }
    }

    /// `actors check` の結果。
    struct ActorsCheck: Encodable {
        var ok = true
        let path: String
        let actors: [ActorLine]
        let warnings: [String]
    }

    /// `transcribe` の確定した 1 件。
    struct Transcript: Encodable {
        let text: String
        var isFinal = true
        let start: Double
        let end: Double
    }

    /// `replay` の結果。
    struct ReplaySummary: Encodable {
        var ok = true
        let sessionId: String
        let batches: Int
        let utterances: Int
        let durationSeconds: Int
        let transcriptPath: String?
        /// 声で分離した話者の数（`--separate`。SPEC §3.14）。分離したときだけ。
        let speakers: Int?
    }

    /// `actors try` のヒント 1 件：名前・確率の平均（名乗りだけのヒントは `null`）・名乗りか。
    struct TryHint: Encodable {
        let name: String
        let probability: Double?
        let introduced: Bool

        init(_ hint: SpeakerHint) {
            name = hint.name
            probability = hint.probability.map(CLIOutput.rounded)
            introduced = hint.introduced
        }
    }

    /// `actors try`（本文 1 つ）の結果：名前のヒント（確定ではない）。
    struct TryResult: Encodable {
        let hints: [TryHint]
    }

    /// 評価の集計（話者の数と、ヒントの当たり方）。
    struct EvalScore: Encodable {
        let speakers: Int
        /// ヒントの先頭が、正解。
        let top1: Int
        /// 正解が、ヒントに出た。
        let shown: Int
        let top1Rate: Double
        let shownRate: Double

        init(_ score: SpeakerEvalScore) {
            speakers = score.speakers; top1 = score.top1; shown = score.shown
            top1Rate = CLIOutput.rounded(score.top1Rate); shownRate = CLIOutput.rounded(score.shownRate)
        }
    }

    /// `actors try --cases` の結果。
    struct EvalReport: Encodable {
        let speakers: Int
        let secondsPerSpeaker: Double
        let total: EvalScore
        let byTag: [String: EvalScore]

        init(_ report: SpeakerEvalReport) {
            speakers = report.speakers
            secondsPerSpeaker = CLIOutput.rounded(report.speakers == 0 ? 0 : report.seconds / Double(report.speakers))
            total = EvalScore(report.total)
            byTag = report.byTag.mapValues(EvalScore.init)
        }
    }

    /// 小数 3 桁に丸める。
    static func rounded(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    /// 1 行の JSON にする（エンコードできなければ `{}`）。
    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
