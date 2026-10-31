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
    /// 確信が足りない文を、前の話者に付けるとき：**前の話者とは別の人が、これ以上の確率で、最も確からしい**なら、付けない（話者が替わった直後の文を、前の話者にしない）。
    public var rivalConfidence: Double

    public init(minimumConfidence: Double = 0.9, maximumFiller: Double = 0.5, rivalConfidence: Double = 0.4) {
        self.minimumConfidence = minimumConfidence
        self.maximumFiller = maximumFiller
        self.rivalConfidence = rivalConfidence
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
    /// 今日の出席者。外された人は、話者の候補にしない（会議の途中で変わり得る。判断のたびに見る）。
    private let attendance: Attendance
    /// 判断の単位（`segments` が使う）。
    public let unit: JudgmentUnit

    public init(list: ActorList, judge: any SpeakerJudge, gate: SpeakerGate = SpeakerGate(), attendance: Attendance = Attendance(), unit: JudgmentUnit = .default) {
        self.list = list
        self.judge = judge
        self.gate = gate
        self.attendance = attendance
        self.unit = unit
    }

    /// 1 つの本文の判断と、その理由（診断：`actors try`）。
    public struct Decision: Equatable, Sendable {
        public enum Outcome: String, Sendable {
            /// 付けた（名乗り）。
            case introduced
            /// 付けた（確信度の条件を満たした）。
            case named
            /// 短すぎて、問わなかった。
            case tooShort
            /// 候補がいない（出席者がいない、または、全員の名前が出た）。
            case noCandidate
            /// 内容を持たない発言（相づち・進行）。
            case filler
            /// 確信度が足りない。
            case lowConfidence
        }

        public let outcome: Outcome
        /// 付けた人（付けなかったときは `nil`）。
        public let actor: Actor?
        /// 判断モデルへ問うた候補と、その答え（問わなかったときは、空・`nil`）。
        public let candidates: [Actor]
        public let answer: SpeakerJudgement?

        /// 判断モデルが、最も確からしいとした人と、その確率（問わなかったとき・答えが壊れているときは `nil`）。
        public var best: (actor: Actor, probability: Double)? {
            guard let answer, answer.probabilities.count == candidates.count,
                  let top = answer.probabilities.indices.max(by: { answer.probabilities[$0] < answer.probabilities[$1] }) else { return nil }
            return (candidates[top], answer.probabilities[top])
        }

        /// `actor` の確率（候補にいない・答えが壊れているときは 0）。
        public func probability(of actor: Actor) -> Double {
            guard let answer, answer.probabilities.count == candidates.count, let index = candidates.firstIndex(of: actor) else { return 0 }
            return answer.probabilities[index]
        }
    }

    public func decide(_ text: String) async throws -> Decision {
        let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard utterance.count >= Self.minimumLength else { return Decision(outcome: .tooShort, actor: nil, candidates: [], answer: nil) }
        let others = attendance.present(list.others)
        guard !others.isEmpty else { return Decision(outcome: .noCandidate, actor: nil, candidates: [], answer: nil) }

        let found = Self.mentions(of: others, in: utterance)
        if found.introduced.count == 1, let only = found.introduced.first { return Decision(outcome: .introduced, actor: others[only], candidates: [], answer: nil) }
        let candidates = others.indices.filter { !found.mentioned.contains($0) }.map { others[$0] }
        guard !candidates.isEmpty else { return Decision(outcome: .noCandidate, actor: nil, candidates: [], answer: nil) }

        let answer = try await judge.judge(utterance: utterance, candidates: candidates)
        guard answer.probabilities.count == candidates.count, let top = answer.probabilities.indices.max(by: { answer.probabilities[$0] < answer.probabilities[$1] }) else {
            return Decision(outcome: .lowConfidence, actor: nil, candidates: candidates, answer: answer)
        }
        if answer.filler >= gate.maximumFiller { return Decision(outcome: .filler, actor: nil, candidates: candidates, answer: answer) }
        if answer.probabilities[top] < gate.minimumConfidence { return Decision(outcome: .lowConfidence, actor: nil, candidates: candidates, answer: answer) }
        return Decision(outcome: .named, actor: candidates[top], candidates: candidates, answer: answer)
    }

    public func guess(_ text: String) async throws -> Actor? {
        try await decide(text).actor
    }

    /// 分割した 1 区間：本文と、付けた名前（付けられなければ `nil`）。
    public struct Segment: Equatable, Sendable {
        public let text: String
        public let actor: Actor?

        public init(text: String, actor: Actor?) {
            self.text = text
            self.actor = actor
        }
    }

    /// 1 つの発話（無音で区切られた単位）を、**話者ごとの区間に分ける**（SPEC §3.13）。
    /// 文（`SentenceSplitter`）ごとに、`guess` と同じ規則・確信度で、話者を判断し、**確信をもって判断された、隣り合う文の話者が、別の人のところで区切る**。
    /// 判断されなかった文（相づち・短い文・確信度が足りない文）は、前の区間に付ける（先頭なら、最初に判断された区間に付ける）。
    /// **ただし、確信度が足りない文で、別の人が、`SpeakerGate.rivalConfidence` 以上の確率で最も確からしいときは、その人でない話者の区間に付けず、名前の無い別の区間にする**（前の区間の話者とは別の人が、前の話者より確からしいとき。先頭の文は、最初に判断された区間の話者とは別の人が、最も確からしいとき。話者が替わった前後の文を、となりの話者にしない。名前の無い区間は、続く確信の足りない文を受け、次に確信した文の話者に、さかのぼって付けない）。
    /// 区切りが無く、どの文も判断されなかったときは、本文全体で、もう一度判断する。文が 1 つなら、これまでどおり、その本文を判断する。
    /// 区間の本文をつなぐと、元の本文に戻る（文の間の空白は、区切りで落ちる）。
    public func segments(_ text: String) async throws -> [Segment] {
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentences = unit == .utterance ? [whole] : SentenceSplitter.split(whole)
        guard sentences.count > 1 else { return [Segment(text: whole, actor: try await guess(whole))] }
        /// `unnamed`：別の人が有力で、わざと名前を付けなかった区間（先頭の、まだ判断されていない区間と、区別する）。`lean`：先頭の、まだ判断されていない区間で、確信が足りないまま有力だった人。
        var groups: [(sentences: [String], actor: Actor?, unnamed: Bool, lean: Actor?)] = []
        func lean(_ decision: Decision) -> Actor? {
            guard decision.outcome == .lowConfidence, let best = decision.best, best.probability >= gate.rivalConfidence else { return nil }
            return best.actor
        }
        for sentence in sentences {
            let decision = try await decide(sentence)
            guard var last = groups.popLast() else { groups.append(([sentence], decision.actor, false, lean(decision))); continue }
            if let found = decision.actor {
                if last.actor == nil, !last.unnamed, let leaning = last.lean, leaning != found {
                    last.unnamed = true; groups.append(last); groups.append(([sentence], found, false, nil))
                } else if last.actor == nil, !last.unnamed {
                    last.actor = found; last.sentences.append(sentence); groups.append(last)
                } else if found != last.actor {
                    groups.append(last); groups.append(([sentence], found, false, nil))
                } else {
                    last.sentences.append(sentence); groups.append(last)
                }
            } else if decision.outcome == .lowConfidence, let previous = last.actor, let best = decision.best, best.actor != previous,
                      best.probability >= gate.rivalConfidence, best.probability > decision.probability(of: previous) {
                groups.append(last); groups.append(([sentence], nil, true, nil))
            } else {
                if last.actor == nil, !last.unnamed, let leaning = lean(decision) { last.lean = leaning }
                last.sentences.append(sentence); groups.append(last)
            }
        }
        if groups.count == 1, groups[0].actor == nil { return [Segment(text: whole, actor: try await guess(whole))] }
        return groups.map { Segment(text: $0.sentences.joined(), actor: $0.actor) }
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
