import Foundation

/// 評価の 1 件：確定した発話 1 つ（文を、話した順に並べたもの。文の間に、空白は入れない）と、各文の正解の話者。
/// 名前のヒント（SPEC §3.13）の当たり方を、同じ入力で、比べるのに使う（`actors try --cases`）。会議の本文ではなく、**合成した文**を使う。
public struct SpeakerEvalCase: Equatable, Sendable, Decodable {
    public struct Sentence: Equatable, Sendable, Decodable {
        public let text: String
        /// 正解の話者（ACTOR.md の相手の側の名前）。`null` は、誰が言ってもよい文（相づちなど。評価には使わない）。
        public let actor: String?

        public init(text: String, actor: String?) {
            self.text = text
            self.actor = actor
        }
    }

    /// 場合の名前（`single`：1 文・`run`：同じ話者の続き・`turn`：話者の入れ替わり、など。集計の単位）。
    public let tag: String
    public let sentences: [Sentence]

    public init(tag: String, sentences: [Sentence]) {
        self.tag = tag
        self.sentences = sentences
    }

    /// JSON Lines（1 行 1 件。空行は読み飛ばす）を読む。読めない行は、行番号つきの理由で断る。
    public static func parse(jsonLines text: String) -> Result<[SpeakerEvalCase], SpeakerEvalError> {
        var cases: [SpeakerEvalCase] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let value = try? JSONDecoder().decode(SpeakerEvalCase.self, from: Data(trimmed.utf8)), !value.sentences.isEmpty else {
                return .failure(.invalidLine(index + 1))
            }
            cases.append(value)
        }
        return cases.isEmpty ? .failure(.empty) : .success(cases)
    }
}

public enum SpeakerEvalError: Error, Equatable, Sendable {
    case empty
    case invalidLine(Int)
    case unknownActor(String)

    public var message: String {
        switch self {
        case .empty: return "評価の件が、1 つもありません"
        case .invalidLine(let line): return "\(line) 行目を読めません（{\"tag\": \"…\", \"sentences\": [{\"text\": \"…\", \"actor\": \"名前\"}]} の形）"
        case .unknownActor(let name): return "正解の話者「\(name)」が、ACTOR.md の相手の側にいません"
        }
    }
}

/// 話者（1 件の中で、同じ正解の名前の文をまとめたもの）の数と、ヒントの当たり方。
public struct SpeakerEvalScore: Equatable, Sendable {
    public var speakers = 0
    /// ヒントの先頭（名乗りがあれば、その人）が、正解。
    public var top1 = 0
    /// 正解が、ヒントに出た（名乗り・上位 3 人のどれか）。
    public var shown = 0

    public init() {}

    public var top1Rate: Double { speakers == 0 ? 0 : Double(top1) / Double(speakers) }
    public var shownRate: Double { speakers == 0 ? 0 : Double(shown) / Double(speakers) }

    mutating func add(truth: String, hints: [SpeakerHint]) {
        speakers += 1
        if hints.first?.name == truth { top1 += 1 }
        if hints.contains(where: { $0.name == truth }) { shown += 1 }
    }

    mutating func add(_ other: SpeakerEvalScore) {
        speakers += other.speakers; top1 += other.top1; shown += other.shown
    }
}

public struct SpeakerEvalReport: Equatable, Sendable {
    public var total = SpeakerEvalScore()
    /// 場合の名前（`tag`）ごと。
    public var byTag: [String: SpeakerEvalScore] = [:]
    /// ヒントを出した話者の数と、判断にかかった合計の秒。
    public var speakers: Int { total.speakers }
    public var seconds = 0.0

    public init() {}
}

public enum SpeakerEvaluation {
    /// 各件の文を、**正解の話者ごとにまとめ**（名前の無い文は、使わない）、その話者の発話として `maker.hints` へ渡し、**正解の名前が、ヒントの先頭・ヒントの中にあるか**を数える。
    /// 実際の名付けの画面と、同じ道（`SpeakerHintMaker`）を通す。
    public static func run(cases: [SpeakerEvalCase], maker: SpeakerHintMaker) async throws -> SpeakerEvalReport {
        var report = SpeakerEvalReport()
        for item in cases {
            var byActor: [String: [String]] = [:]
            for sentence in item.sentences { if let actor = sentence.actor { byActor[actor, default: []].append(sentence.text) } }
            for (actor, texts) in byActor.sorted(by: { $0.key < $1.key }) {
                let started = Date()
                let hints = try await maker.hints(for: texts)
                report.seconds += Date().timeIntervalSince(started)
                report.total.add(truth: actor, hints: hints)
                report.byTag[item.tag, default: SpeakerEvalScore()].add(truth: actor, hints: hints)
            }
        }
        return report
    }
}
