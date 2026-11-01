import Foundation

/// 判断モデル（System One 型）の答え。閉じた選択肢に、確率を返す。
public struct SpeakerJudgement: Equatable, Sendable {
    /// 候補ごとの、その人が話した確率（候補の順。合計 1）。
    public let probabilities: [Double]
    /// 「内容を持たない発言（相づち・同意・あいさつ・進行の言葉だけ）」である確率。
    public let filler: Double

    public init(probabilities: [Double], filler: Double) {
        self.probabilities = probabilities
        self.filler = filler
    }
}

/// 判断モデル。実機は、ダウンロードした System One 型のモデル（`SystemOneJudge`）。テストは、決まった答えを返す偽物。
/// 名前のヒント（`SpeakerHintMaker`。SPEC §3.13）が使う。**名前を決めるのは、人間**（判断モデルは、確率を返すだけ）。
public protocol SpeakerJudge: Sendable {
    /// `candidates` の中で、その発言をした人の確率と、内容を持たない発言である確率。候補が 1 人のときは、`probabilities` は `[1]`。
    func judge(utterance: String, candidates: [Actor]) async throws -> SpeakerJudgement
}

/// 判断モデルへ渡す問いの文面。
public enum SpeakerPrompt {
    /// 「誰が話したか」（選択肢）の問い。
    public static let whoQuestion = "この発言を話した人は誰か"
    /// 「内容を持たない発言か」（真偽）の問い。
    public static let fillerQuestion = "この発言は、相づち・同意・あいさつ・進行の言葉だけで、内容を持たない"
    static let maxDescriptionLength = 60

    /// 選択肢の 1 行：「名前: 役割（話題: a・b）」。長い説明は、切る（入力の長さに、上限があるため）。
    public static func option(_ actor: Actor) -> String {
        var line = actor.name
        var detail = actor.role ?? ""
        if !actor.topics.isEmpty { detail += (detail.isEmpty ? "" : "。") + "話題: " + actor.topics.joined(separator: "・") }
        if !detail.isEmpty { line += ": " + String(detail.prefix(maxDescriptionLength)) }
        return line
    }
}
