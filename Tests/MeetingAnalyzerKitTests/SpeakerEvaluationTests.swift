import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("判断の単位：文ごと／発話ごと")
struct JudgmentUnitTests {
    private let a = "マイグレーションの手順をまとめました。"   // 佐藤
    private let b = "月末の請求書の承認をお願いします。"        // 田中

    private func guesser(_ unit: JudgmentUnit) throws -> SpeakerGuesser {
        SpeakerGuesser(list: try actorList(), judge: KeywordJudge(), unit: unit)
    }

    @Test("文ごと：話者が入れ替わる発話を、文で分けて、それぞれに名前を付ける。発話ごと：分けず、1 回で判断する（2 人分の手がかりが混ざって、確信が足りず、付かない）")
    func mixedUtterance() async throws {
        let sentence = try await guesser(.sentence).segments(a + b)
        #expect(sentence.map(\.text) == [a, b] && sentence.map { $0.actor?.name } == ["佐藤 花子", "田中 美咲"])
        let utterance = try await guesser(.utterance).segments(a + b)
        #expect(utterance.map(\.text) == [a + b] && utterance.map { $0.actor?.name } == [nil])
    }

    @Test("同じ話者の文が続く発話は、どちらの単位でも、その人に付く。単位が違っても、1 文の発話は同じ")
    func sameSpeakerRun() async throws {
        let run = a + "データベースのインデックスも見直します。"
        for unit in JudgmentUnit.allCases {
            let segments = try await guesser(unit).segments(run)
            #expect(segments.map { $0.actor?.name } == ["佐藤 花子"], "\(unit)")
        }
        let single = try await guesser(.sentence).segments(b)
        #expect(single == (try await guesser(.utterance).segments(b)))
    }
}

@Suite("判断の理由（Decision）")
struct DecisionTests {
    private func decide(_ text: String, judge: FakeJudge = FakeJudge(), attendance: Attendance = Attendance()) async throws -> SpeakerGuesser.Decision {
        try await SpeakerGuesser(list: try actorList(), judge: judge, attendance: attendance).decide(text)
    }

    @Test("付けた・付けなかった理由が、区別できる：短い・候補がいない・内容を持たない・確信が足りない・名乗り・付けた")
    func outcomes() async throws {
        #expect(try await decide("はい").outcome == .tooShort)

        let none = Attendance()
        none.replace(excluded: ["佐藤 花子", "田中 美咲"])
        #expect(try await decide("今日の議題を確認します。", attendance: none).outcome == .noCandidate)

        let filler = FakeJudge()
        filler.probabilities = ["佐藤 花子": 0.99]
        filler.filler = 0.9
        #expect(try await decide("そうですね、わかりました。", judge: filler).outcome == .filler)

        let unsure = FakeJudge()
        unsure.probabilities = ["佐藤 花子": 0.6, "田中 美咲": 0.4]
        let weak = try await decide("来週の予定を確認します。", judge: unsure)
        #expect(weak.outcome == .lowConfidence && weak.actor == nil && weak.answer != nil && weak.candidates.count == 2)

        #expect(try await decide("佐藤です。来週の予定を確認します。").outcome == .introduced)

        let sure = FakeJudge()
        sure.probabilities = ["佐藤 花子": 0.97, "田中 美咲": 0.03]
        let named = try await decide("来週の予定を確認します。", judge: sure)
        #expect(named.outcome == .named && named.actor?.name == "佐藤 花子")
    }
}

@Suite("評価（SpeakerEvaluation）：件の読み取りと、文ごとの採点")
struct SpeakerEvaluationTests {
    private func cases() -> [SpeakerEvalCase] {
        typealias S = SpeakerEvalCase.Sentence
        let a = "マイグレーションの手順をまとめました。", b = "月末の請求書の承認をお願いします。"
        return [
            SpeakerEvalCase(tag: "turn", sentences: [S(text: a, actor: "佐藤 花子"), S(text: b, actor: "田中 美咲")]),
            SpeakerEvalCase(tag: "run", sentences: [S(text: a, actor: "佐藤 花子"), S(text: "データベースのインデックスも見直します。", actor: "佐藤 花子")]),
            SpeakerEvalCase(tag: "filler", sentences: [S(text: "そうですね、わかりました。", actor: nil)]),
        ]
    }

    @Test("文ごとに、その文を含む区間の名前と比べて、正解・間違い・付けなかったを数え、場合の名前ごとにも集計する。単位で結果が変わる")
    func scoring() async throws {
        let list = try actorList()
        let bySentence = try await SpeakerEvaluation.run(cases: cases(), guesser: SpeakerGuesser(list: list, judge: KeywordJudge(), unit: .sentence))
        #expect(bySentence.total.sentences == 5 && bySentence.total.correct == 4 && bySentence.total.wrong == 0 && bySentence.total.rightlyUnnamed == 1)
        #expect(bySentence.byTag["turn"]?.correct == 2 && bySentence.cases == 3)

        let byUtterance = try await SpeakerEvaluation.run(cases: cases(), guesser: SpeakerGuesser(list: list, judge: KeywordJudge(), unit: .utterance))
        #expect(byUtterance.byTag["turn"]?.missed == 2, "混ざった発話は、まとめて判断すると、確信が足りず、付かない")
        #expect(byUtterance.byTag["run"]?.correct == 2 && byUtterance.total.wrong == 0)
    }

    @Test("確信して別の人に付けた文は「間違い」、付けないのが正解の文に付けたら「付けすぎ」。付けた中の正解の割合を出す")
    func wrongAndFalseName() async throws {
        // 判断モデルが、いつも佐藤に確信する（田中の文も、相づちも、佐藤に付く）。
        let always = FakeJudge()
        always.probabilities = ["佐藤 花子": 0.99, "田中 美咲": 0.01]
        let report = try await SpeakerEvaluation.run(cases: cases(), guesser: SpeakerGuesser(list: try actorList(), judge: always, unit: .sentence))
        #expect(report.total.wrong == 1 && report.total.falseName == 1 && report.total.correct == 3)
        #expect(report.total.named == 5 && report.total.precision == 0.6)
    }

    @Test("JSON Lines：空行は読み飛ばす。読めない行は、行番号つきで断る。件が無ければ断る")
    func parsing() {
        let good = #"{"tag":"single","sentences":[{"text":"こんにちは、会議を始めます。","actor":null}]}"#
        guard case .success(let parsed) = SpeakerEvalCase.parse(jsonLines: good + "\n\n" + good + "\n") else { Issue.record("読めない"); return }
        #expect(parsed.count == 2 && parsed[0].text == "こんにちは、会議を始めます。" && parsed[0].sentences[0].actor == nil)
        #expect(SpeakerEvalCase.parse(jsonLines: good + "\nこれは JSON ではない\n") == .failure(.invalidLine(2)))
        #expect(SpeakerEvalCase.parse(jsonLines: #"{"tag":"x","sentences":[]}"#) == .failure(.invalidLine(1)), "文が無い件は、断る")
        #expect(SpeakerEvalCase.parse(jsonLines: "\n  \n") == .failure(.empty))
    }

    @Test("同梱の評価セット（eval/）が、同梱の ACTOR.md と合っている：全件を読め、正解の名前が、すべて相手の側にいる")
    func bundledEvalSetIsConsistent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("eval")
        let text = try String(contentsOf: root.appendingPathComponent("cases.jsonl"), encoding: .utf8)
        let parsed = try SpeakerEvalCase.parse(jsonLines: text).get()
        for file in ["actors-nouns.md", "actors-phrases.md"] {
            let list = try ActorList.parse(String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)).get()
            let known = Set(list.others.map(\.name))
            #expect(parsed.flatMap(\.sentences).compactMap(\.actor).allSatisfy(known.contains), "\(file)")
            #expect(list.warnings.isEmpty, "\(file)")
        }
        #expect(Set(parsed.map(\.tag)) == ["single", "run", "turn", "turn3", "filler"])
    }
}

@Suite("CLI の引数：actors try と、replay の --unit")
struct ActorsTryCommandTests {
    @Test("actors try：本文 1 つ、または、--cases。--judge が要る。単位は、既定が文ごとで、both なら両方")
    func parsesTry() {
        guard case .success(.actorsTry(let one)) = CommandParser.parse(["actors", "try", "A.md", "--judge", "tiny-jev-0.6b", "来週の予定です"]) else { Issue.record("parse failed"); return }
        #expect(one.file == "A.md" && one.judge == "tiny-jev-0.6b" && one.units == [.sentence] && one.input == .text("来週の予定です") && one.attendees == nil)

        guard case .success(.actorsTry(let both)) = CommandParser.parse(["actors", "try", "A.md", "--judge", "tiny-jev-1.7b", "--unit", "both", "--attendees", "佐藤 花子、田中 美咲", "--cases", "c.jsonl"]) else { Issue.record("parse failed"); return }
        #expect(both.units == [.sentence, .utterance] && both.input == .cases("c.jsonl") && both.attendees == ["佐藤 花子", "田中 美咲"])

        guard case .success(.actorsTry(let utterance)) = CommandParser.parse(["actors", "try", "A.md", "--judge", "tiny-jev-0.6b", "--unit", "utterance", "本文です、確認"]) else { Issue.record("parse failed"); return }
        #expect(utterance.units == [.utterance])
        #expect(one.gate == SpeakerGate(), "無指定は、会議と同じ既定")

        guard case .success(.actorsTry(let gated)) = CommandParser.parse(["actors", "try", "A.md", "--judge", "tiny-jev-0.6b", "--min-confidence", "0.7", "--rival", "0", "--max-filler", "1", "本文です、確認"]) else { Issue.record("parse failed"); return }
        #expect(gated.gate == SpeakerGate(minimumConfidence: 0.7, maximumFiller: 1, rivalConfidence: 0), "0 と 1（端）も使える。指定しないものは、既定のまま")
    }

    @Test("actors try：--judge が無い・知らない判断モデル・知らない単位・本文も --cases も無い・--cases と本文の両方は、使い方の誤り")
    func rejectsTry() {
        let bad: [[String]] = [
            ["actors", "try", "A.md", "本文です"],
            ["actors", "try", "A.md", "--judge", "nope", "本文です"],
            ["actors", "try", "A.md", "--judge", "tiny-jev-0.6b", "--unit", "word", "本文です"],
            ["actors", "try", "A.md", "--judge", "tiny-jev-0.6b"],
            ["actors", "try", "A.md", "--judge", "tiny-jev-0.6b", "--cases", "c.jsonl", "本文です"],
            ["actors", "try", "A.md", "--judge", "tiny-jev-0.6b", "--min-confidence", "1.5", "本文です"],
            ["actors", "try", "A.md", "--judge", "tiny-jev-0.6b", "--rival", "-0.1", "本文です"],
            ["actors", "try", "A.md", "--judge", "tiny-jev-0.6b", "--max-filler", "high", "本文です"],
        ]
        for arguments in bad {
            guard case .failure(.usage) = CommandParser.parse(arguments) else { Issue.record("\(arguments) を断らない"); return }
        }
    }

    @Test("replay --unit：sentence か utterance（both は、replay では使えない）。無指定は、文ごと")
    func parsesReplayUnit() {
        guard case .success(.replay(let plain)) = CommandParser.parse(["replay", "a.wav"]) else { Issue.record("parse failed"); return }
        #expect(plain.unit == .sentence)
        guard case .success(.replay(let utterance)) = CommandParser.parse(["replay", "a.wav", "--unit", "utterance"]) else { Issue.record("parse failed"); return }
        #expect(utterance.unit == .utterance)
        guard case .failure(.usage) = CommandParser.parse(["replay", "a.wav", "--unit", "both"]) else { Issue.record("both を断らない"); return }
    }
}

/// 文ごとに、決めた確率を返す判断モデル（`answers[文][名前]`。無い名前は 0。「内容を持たない」確率は 0）。
private struct ScriptedJudge: SpeakerJudge {
    let answers: [String: [String: Double]]

    func judge(utterance: String, candidates: [Actor]) async throws -> SpeakerJudgement {
        SpeakerJudgement(probabilities: candidates.map { answers[utterance]?[$0.name] ?? 0 }, filler: 0)
    }
}

@Suite("確信が足りない文：別の人が有力なら、前の話者に付けない（SPEC §3.13）")
struct RivalSentenceTests {
    private let first = "この画面の表示が遅いのは、検索が重いからです。"        // 佐藤（確信）
    private let weak = "来月の予算の消化が早いので、見直しましょう。"           // 確信が足りない文
    private let more = "あわせて、支払いの承認の流れも確認します。"             // 確信が足りない文（続き）
    private let last = "もう一つ、障害の連絡の手順を決めておきます。"           // 佐藤（確信）
    private let sato = "佐藤 花子", tanaka = "田中 美咲"

    private func segments(_ answers: [String: [String: Double]], _ sentences: [String], gate: SpeakerGate = SpeakerGate()) async throws -> [SpeakerGuesser.Segment] {
        let guesser = SpeakerGuesser(list: try actorList(), judge: ScriptedJudge(answers: answers), gate: gate)
        return try await guesser.segments(sentences.joined())
    }

    @Test("確信が足りない文で、前の話者とは別の人が、0.4 以上で、前の話者より有力なら、前の話者に付けず、名前の無い別の発話にする")
    func rivalIsNotAttached() async throws {
        let result = try await segments([first: [sato: 0.97, tanaka: 0.03], weak: [sato: 0.3, tanaka: 0.6]], [first, weak])
        #expect(result.map { $0.actor?.name } == [sato, nil] && result.map(\.text) == [first, weak])
    }

    @Test("別の人が有力でなければ、これまでどおり、前の話者に付く：前の話者が最上位／別の人が 0.4 未満／前の話者と同点")
    func otherwiseAttachesToThePrevious() async throws {
        let leading = try await segments([first: [sato: 0.97, tanaka: 0.03], weak: [sato: 0.6, tanaka: 0.4]], [first, weak])
        #expect(leading.count == 1 && leading[0].actor?.name == sato)
        let faint = try await segments([first: [sato: 0.97, tanaka: 0.03], weak: [sato: 0.3, tanaka: 0.35]], [first, weak])
        #expect(faint.count == 1 && faint[0].actor?.name == sato, "0.4 未満の別の人は、有力とみなさない")
        let tie = try await segments([first: [sato: 0.97, tanaka: 0.03], weak: [sato: 0.5, tanaka: 0.5]], [first, weak])
        #expect(tie.count == 1 && tie[0].actor?.name == sato, "同点は、前の話者のまま（どちらかに決める根拠が無い）")
        let loose = try await segments([first: [sato: 0.97, tanaka: 0.03], weak: [sato: 0.3, tanaka: 0.6]], [first, weak], gate: SpeakerGate(rivalConfidence: 0.7))
        #expect(loose.count == 1, "しきい値（`SpeakerGate.rivalConfidence`）を上げると、付かない文は減る")
    }

    @Test("名前の無い発話は、続く確信の足りない文を受け、次に確信した文の話者に、さかのぼって付けない。確信した文は、新しい発話になる")
    func unnamedSegmentIsKept() async throws {
        let answers = [
            first: [sato: 0.97, tanaka: 0.03],
            weak: [sato: 0.3, tanaka: 0.6],
            more: [sato: 0.45, tanaka: 0.2],
            last: [sato: 0.96, tanaka: 0.04],
        ]
        let result = try await segments(answers, [first, weak, more, last])
        #expect(result.map { $0.actor?.name } == [sato, nil, sato], "続きの文（more）は、名前の無い発話に入り、last は新しい発話")
        #expect(result.map(\.text) == [first, weak + more, last])
    }

    @Test("先頭の、確信が足りない文：最初に確信した話者とは別の人が有力なら、その話者に付けない。同じ人が有力（または有力な人がいない）なら、付ける")
    func leadingSentence() async throws {
        let apart = try await segments([weak: [sato: 0.3, tanaka: 0.6], first: [sato: 0.97, tanaka: 0.03]], [weak, first])
        #expect(apart.map { $0.actor?.name } == [nil, sato] && apart.map(\.text) == [weak, first])
        let same = try await segments([weak: [sato: 0.6, tanaka: 0.3], first: [sato: 0.97, tanaka: 0.03]], [weak, first])
        #expect(same.count == 1 && same[0].actor?.name == sato)
        let faint = try await segments([weak: [sato: 0.2, tanaka: 0.3], first: [sato: 0.97, tanaka: 0.03]], [weak, first])
        #expect(faint.count == 1 && faint[0].actor?.name == sato, "有力な人（0.4 以上）がいなければ、これまでどおり、最初に判断された区間に付く")
    }

    @Test("相づち（内容を持たない）や、短い文は、別の人が有力に見えても、これまでどおり、前の話者に付く")
    func fillersStillAttach() async throws {
        let filler = ScriptedFillerJudge()
        let guesser = SpeakerGuesser(list: try actorList(), judge: filler)
        let result = try await guesser.segments("マイグレーションの手順をまとめました。そうですね、わかりました。")
        #expect(result.count == 1 && result[0].actor?.name == sato)
    }
}

/// 1 文目は佐藤に確信し、相づちには、「内容を持たない」確率を高く返す（確率は、田中に傾けても、相づちとして扱う）。
private struct ScriptedFillerJudge: SpeakerJudge {
    func judge(utterance: String, candidates: [Actor]) async throws -> SpeakerJudgement {
        if utterance.hasPrefix("そうですね") { return SpeakerJudgement(probabilities: candidates.map { $0.name == "田中 美咲" ? 0.7 : 0.3 }, filler: 0.95) }
        return SpeakerJudgement(probabilities: candidates.map { $0.name == "佐藤 花子" ? 0.97 : 0.03 }, filler: 0)
    }
}
