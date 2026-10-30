import Foundation

/// 発話に付ける、アクターの名前。`guessed` は、内容から判断モデルが選んだ推定（間違い得る）。マイクの「本人」を、`ACTOR.md` の本人へ対応づけたものは、推定ではない。
public struct ActorLabel: Equatable, Sendable, Codable {
    public let name: String
    public let guessed: Bool

    public init(name: String, guessed: Bool) {
        self.name = name
        self.guessed = guessed
    }
}

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
public protocol SpeakerJudge: Sendable {
    /// `candidates` の中で、その発言をした人の確率と、内容を持たない発言である確率。候補が 1 人のときは、`probabilities` は `[1]`。
    func judge(utterance: String, candidates: [Actor]) async throws -> SpeakerJudgement
}

/// 名前を付けてよいかの、確信度の条件（**暫定の値**）。合成の 30 発言を見て決めた値で、実会議の文字起こしで、決め直す必要がある（SPEC §11）。
public struct SpeakerGate: Sendable, Equatable {
    /// 最も確からしい人の確率が、これ以上のときだけ付ける。
    public var minimumConfidence: Double
    /// 「内容を持たない発言」の確率が、これ未満のときだけ付ける。
    public var maximumFiller: Double

    public init(minimumConfidence: Double = 0.9, maximumFiller: Double = 0.5) {
        self.minimumConfidence = minimumConfidence
        self.maximumFiller = maximumFiller
    }
}

/// 発言の内容だけから、相手（システム音声）の誰が話したかを推定する（SPEC §3.13）。
///
/// 規則は、モデルに任せず、ここ（コード）で決める：①短すぎる発言は、付けない。②「山田です」のような、名乗りがあれば、その人（モデルを使わない）。
/// ③名前が出た人（呼びかけ・言及）は、話者の候補から外す。④判断モデルの確率で、**確信度が足りない・内容を持たない発言（相づち・進行）は、付けない**（`SpeakerGate`）。
/// **付けられなければ `nil`**（呼び出し側は、「相手」のままにする）。
public struct SpeakerGuesser: Sendable {
    /// これより短い発言は、手がかりが無いとみなして、モデルへ問わない。
    static let minimumLength = 6

    public let list: ActorList
    private let judge: any SpeakerJudge
    private let gate: SpeakerGate

    public init(list: ActorList, judge: any SpeakerJudge, gate: SpeakerGate = SpeakerGate()) {
        self.list = list
        self.judge = judge
        self.gate = gate
    }

    public func guess(_ text: String) async throws -> Actor? {
        let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard utterance.count >= Self.minimumLength else { return nil }
        let others = list.others
        guard !others.isEmpty else { return nil }

        let found = Self.mentions(of: others, in: utterance)
        if found.introduced.count == 1, let only = found.introduced.first { return others[only] }
        let candidates = others.indices.filter { !found.mentioned.contains($0) }.map { others[$0] }
        guard !candidates.isEmpty else { return nil }

        let answer = try await judge.judge(utterance: utterance, candidates: candidates)
        guard answer.probabilities.count == candidates.count, answer.filler < gate.maximumFiller,
              let top = answer.probabilities.indices.max(by: { answer.probabilities[$0] < answer.probabilities[$1] }),
              answer.probabilities[top] >= gate.minimumConfidence else { return nil }
        return candidates[top]
    }

    private static let introductions = ["です", "と申します", "といいます", "と言います", "でございます"]

    /// 発言に名前が出た人（`others` の位置）。`introduced`：名乗り（「山田です」）だけで出てきた人。`mentioned`：呼びかけ・言及で出た人（名乗りだけの人は含まない）。
    /// 2 人以上に共通の語（同じ姓など）は、誰のことか決まらないので、使わない。
    static func mentions(of actors: [Actor], in text: String) -> (mentioned: Set<Int>, introduced: Set<Int>) {
        var owners: [String: Set<Int>] = [:]
        for (index, actor) in actors.enumerated() {
            for term in actor.mentionTerms { owners[term.lowercased(), default: []].insert(index) }
        }
        var mentioned = Set<Int>(), introduced = Set<Int>()
        let lowered = text.lowercased()
        for (term, who) in owners where who.count == 1 {
            guard let index = who.first else { continue }
            let honorific = Actor.honorifics.contains { term.hasSuffix($0) }
            var from = lowered.startIndex
            var plain = false, introducing = false
            while let range = lowered.range(of: term, range: from..<lowered.endIndex) {
                let after = lowered[range.upperBound...]
                if !honorific, introductions.contains(where: { after.hasPrefix($0) }) { introducing = true } else { plain = true }
                from = range.upperBound
            }
            if plain { mentioned.insert(index) } else if introducing { introduced.insert(index) }
        }
        // 呼びかけ・言及と、名乗りの両方に出る人は、言及を優先する（名乗りだけで決めない）。
        introduced.subtract(mentioned)
        return (mentioned, introduced)
    }
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
