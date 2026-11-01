import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("評価（SpeakerEvaluation）：件の読み取りと、話者ごとのヒントの採点")
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

    @Test("正解の話者ごとに、その話者の文をまとめて、ヒントを出し、先頭が正解か・ヒントに出たかを数える。名前の無い文は、使わない。場合の名前ごとにも集計する")
    func scoring() async throws {
        let maker = SpeakerHintMaker(list: try actorList(), judge: KeywordJudge())
        let report = try await SpeakerEvaluation.run(cases: cases(), maker: maker)
        #expect(report.speakers == 3, "turn：2 人・run：1 人。filler は、正解の話者がいない")
        #expect(report.total.top1 == 3 && report.total.shown == 3 && report.total.top1Rate == 1)
        #expect(report.byTag["turn"]?.speakers == 2 && report.byTag["run"]?.speakers == 1 && report.byTag["filler"] == nil)
    }

    @Test("ヒントの先頭が別の人なら、先頭は不正解。正解がヒントに出ていれば「ヒントに出た」には数える")
    func wrongTopButShown() async throws {
        // 判断モデルが、いつも佐藤を最上位にする（田中の文も、佐藤が先頭）。
        let always = FakeJudge()
        always.probabilities = ["佐藤 花子": 0.7, "田中 美咲": 0.3]
        let report = try await SpeakerEvaluation.run(cases: cases(), maker: SpeakerHintMaker(list: try actorList(), judge: always))
        #expect(report.total.speakers == 3 && report.total.top1 == 2, "田中の話者だけ、先頭が不正解")
        #expect(report.total.shown == 3 && report.total.shownRate == 1, "田中は、2 番目に出ている")
        #expect(report.total.top1Rate > 0.66 && report.total.top1Rate < 0.67)
    }

    @Test("JSON Lines：空行は読み飛ばす。読めない行は、行番号つきで断る。件が無ければ断る")
    func parsing() {
        let good = #"{"tag":"single","sentences":[{"text":"こんにちは、会議を始めます。","actor":null}]}"#
        guard case .success(let parsed) = SpeakerEvalCase.parse(jsonLines: good + "\n\n" + good + "\n") else { Issue.record("読めない"); return }
        #expect(parsed.count == 2 && parsed[0].sentences[0].text == "こんにちは、会議を始めます。" && parsed[0].sentences[0].actor == nil)
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

@Suite("CLI の引数：actors try")
struct ActorsTryCommandTests {
    @Test("actors try：本文 1 つ、または、--cases。--judge が要る。--attendees は、名前を区切って渡せる")
    func parsesTry() {
        guard case .success(.actorsTry(let one)) = CommandParser.parse(["actors", "try", "A.md", "--judge", "tiny-jev-0.6b", "来週の予定です"]) else { Issue.record("parse failed"); return }
        #expect(one.file == "A.md" && one.judge == "tiny-jev-0.6b" && one.input == .text("来週の予定です") && one.attendees == nil)

        guard case .success(.actorsTry(let cases)) = CommandParser.parse(["actors", "try", "A.md", "--judge", "tiny-jev-1.7b", "--attendees", "佐藤 花子、田中 美咲", "--cases", "c.jsonl"]) else { Issue.record("parse failed"); return }
        #expect(cases.input == .cases("c.jsonl") && cases.attendees == ["佐藤 花子", "田中 美咲"])
    }

    @Test("actors try：--judge が無い・知らない判断モデル・本文も --cases も無い・--cases と本文の両方・廃止したオプション（--unit・--min-confidence・--max-filler・--rival）は、使い方の誤り")
    func rejectsTry() {
        let bad: [[String]] = [
            ["actors", "try", "A.md", "本文です"],
            ["actors", "try", "A.md", "--judge", "nope", "本文です"],
            ["actors", "try", "A.md", "--judge", "tiny-jev-0.6b"],
            ["actors", "try", "A.md", "--judge", "tiny-jev-0.6b", "--cases", "c.jsonl", "本文です"],
            ["actors", "try", "A.md", "--judge", "tiny-jev-0.6b", "--unit", "sentence", "本文です"],
            ["actors", "try", "A.md", "--judge", "tiny-jev-0.6b", "--min-confidence", "0.7", "本文です"],
            ["actors", "try", "A.md", "--judge", "tiny-jev-0.6b", "--max-filler", "0.5", "本文です"],
            ["actors", "try", "A.md", "--judge", "tiny-jev-0.6b", "--rival", "0.4", "本文です"],
        ]
        for arguments in bad {
            guard case .failure(.usage) = CommandParser.parse(arguments) else { Issue.record("\(arguments) を断らない"); return }
        }
    }

    @Test("replay：会議の最中の推定をやめたので、--judge・--attendees・--unit は、使い方の誤り。--actors は、使える")
    func replayNoLongerGuesses() {
        for option in [["--judge", "tiny-jev-0.6b"], ["--attendees", "佐藤 花子"], ["--unit", "sentence"]] {
            guard case .failure(.usage) = CommandParser.parse(["replay", "a.wav", "--actors", "ACTOR.md"] + option) else { Issue.record("\(option) を断らない"); return }
        }
        guard case .success(.replay(let options)) = CommandParser.parse(["replay", "a.wav", "--actors", "ACTOR.md"]) else { Issue.record("parse failed"); return }
        #expect(options.actors == "ACTOR.md")
    }
}
