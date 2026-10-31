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

    /// `actors try` の区間 1 つ：本文・付けた名前（無ければ `null`）・理由（`SpeakerGuesser.Decision.Outcome`）・「内容を持たない」確率・上位の候補の確率。
    struct TrySegment: Encodable {
        let text: String
        let actor: String?
        let outcome: String
        let filler: Double?
        let top: [TryCandidate]
    }

    struct TryCandidate: Encodable {
        let name: String
        let probability: Double
    }

    /// 判断の条件（`SpeakerGate`）。結果が、どの条件のものかが分かるように、結果に添える。
    struct Gate: Encodable {
        let minConfidence: Double
        let maxFiller: Double
        let rival: Double

        init(_ gate: SpeakerGate) {
            minConfidence = gate.minimumConfidence; maxFiller = gate.maximumFiller; rival = gate.rivalConfidence
        }

        /// 人が読む形（`確信度 ≥0.9・内容なし <0.5・別の人 ≥0.4`）。
        var text: String { "確信度 ≥\(minConfidence)・内容なし <\(maxFiller)・別の人 ≥\(rival)" }
    }

    /// `actors try`（本文 1 つ）の結果：判断の単位ごと。
    struct TryResult: Encodable {
        let unit: String
        let gate: Gate
        let segments: [TrySegment]
    }

    /// 評価の集計（文の数と、判断の結果の内訳）。
    struct EvalScore: Encodable {
        let sentences: Int
        let named: Int
        let correct: Int
        /// 確信して間違い（別の人を付けた）。
        let wrong: Int
        let missed: Int
        let falseName: Int
        let rightlyUnnamed: Int
        /// 名前を付けた文のうち、正解の割合。
        let precision: Double

        init(_ score: SpeakerEvalScore) {
            sentences = score.sentences; named = score.named; correct = score.correct; wrong = score.wrong
            missed = score.missed; falseName = score.falseName; rightlyUnnamed = score.rightlyUnnamed
            precision = CLIOutput.rounded(score.precision)
        }
    }

    /// `actors try --cases` の結果：判断の単位ごと。
    struct EvalReport: Encodable {
        let unit: String
        let gate: Gate
        let cases: Int
        let secondsPerCase: Double
        let total: EvalScore
        let byTag: [String: EvalScore]

        init(_ report: SpeakerEvalReport, unit: String, gate: SpeakerGate) {
            self.unit = unit
            self.gate = Gate(gate)
            cases = report.cases
            secondsPerCase = CLIOutput.rounded(report.cases == 0 ? 0 : report.seconds / Double(report.cases))
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
