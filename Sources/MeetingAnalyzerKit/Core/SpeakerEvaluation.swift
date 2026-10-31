import Foundation

/// 評価の 1 件：確定した発話 1 つ（文を、話した順に並べたもの。文の間に、空白は入れない）と、各文の正解の話者。
/// 話者判断の工夫（判断の単位・説明の書き方など）を、同じ入力で、比べるのに使う（`actors try --cases`）。会議の本文ではなく、**合成した文**を使う。
public struct SpeakerEvalCase: Equatable, Sendable, Decodable {
    public struct Sentence: Equatable, Sendable, Decodable {
        public let text: String
        /// 正解の話者（ACTOR.md の相手の側の名前）。`null` は、付けないのが正解（相づちなど）。
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

    /// 確定した発話の本文（文をつないだもの）。
    public var text: String { sentences.map(\.text).joined() }

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

/// 文の数と、判断の結果の内訳。
public struct SpeakerEvalScore: Equatable, Sendable {
    public var sentences = 0
    /// 名前を付けて、正解。
    public var correct = 0
    /// 名前を付けて、別の人（**確信して間違い**）。
    public var wrong = 0
    /// 付けるのが正解の文に、付けなかった。
    public var missed = 0
    /// 付けないのが正解で、付けなかった。
    public var rightlyUnnamed = 0
    /// 付けないのが正解の文に、名前を付けた。
    public var falseName = 0

    public init() {}

    /// 名前を付けた文の数。
    public var named: Int { correct + wrong + falseName }
    /// 名前を付けた文のうち、正解の割合。
    public var precision: Double { named == 0 ? 0 : Double(correct) / Double(named) }

    mutating func add(truth: String?, predicted: String?) {
        sentences += 1
        switch (truth, predicted) {
        case let (truth?, predicted?): if truth == predicted { correct += 1 } else { wrong += 1 }
        case (_?, nil): missed += 1
        case (nil, nil): rightlyUnnamed += 1
        case (nil, _?): falseName += 1
        }
    }

    mutating func add(_ other: SpeakerEvalScore) {
        sentences += other.sentences; correct += other.correct; wrong += other.wrong
        missed += other.missed; rightlyUnnamed += other.rightlyUnnamed; falseName += other.falseName
    }
}

public struct SpeakerEvalReport: Equatable, Sendable {
    public var total = SpeakerEvalScore()
    /// 場合の名前（`tag`）ごと。
    public var byTag: [String: SpeakerEvalScore] = [:]
    /// 発話（件）の数と、判断にかかった合計の秒。
    public var cases = 0
    public var seconds = 0.0

    public init() {}
}

public enum SpeakerEvaluation {
    /// 各件を、`guesser.segments`（実際の会議と同じ道）で判断し、**正解の文ごとに、その文の先頭を含む区間の名前**と比べる。
    public static func run(cases: [SpeakerEvalCase], guesser: SpeakerGuesser) async throws -> SpeakerEvalReport {
        var report = SpeakerEvalReport()
        for item in cases {
            let started = Date()
            let segments = try await guesser.segments(item.text)
            report.seconds += Date().timeIntervalSince(started)
            report.cases += 1
            var score = SpeakerEvalScore()
            var offset = 0
            for sentence in item.sentences {
                score.add(truth: sentence.actor, predicted: actor(at: offset, in: segments)?.name)
                offset += sentence.text.count
            }
            report.total.add(score)
            report.byTag[item.tag, default: SpeakerEvalScore()].add(score)
        }
        return report
    }

    /// 本文の `offset` 文字目を含む区間の名前（区間の本文をつなぐと、元の本文になる）。
    static func actor(at offset: Int, in segments: [SpeakerGuesser.Segment]) -> Actor? {
        var start = 0
        for segment in segments {
            let end = start + segment.text.count
            if offset < end { return segment.actor }
            start = end
        }
        return segments.last?.actor
    }
}
