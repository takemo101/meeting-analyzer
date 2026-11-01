import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("名前のヒント：話者の発話から、上位 3 人（確定ではない。SPEC §3.13）")
struct SpeakerHintMakerTests {
    private func maker(_ judge: any SpeakerJudge, attendance: Attendance = Attendance()) throws -> SpeakerHintMaker {
        SpeakerHintMaker(list: try actorList(), judge: judge, attendance: attendance)
    }

    @Test("発話ごとの確率を平均して、高い順に返す（確率のしきい値で、人を落とさない）")
    func averagesAcrossUtterances() async throws {
        let hints = try await maker(KeywordJudge()).hints(for: ["マイグレーションとデータベースの話です", "APIの設計を見直します", "経理の月末処理についてです"])
        #expect(hints.map(\.name) == ["佐藤 花子", "田中 美咲"])
        #expect(abs((hints[0].probability ?? 0) - (0.97 + 0.97 + 0.03) / 3) < 1e-9 && abs((hints[1].probability ?? 0) - (0.03 + 0.03 + 0.97) / 3) < 1e-9)
        #expect(hints.allSatisfy { !$0.introduced })
    }

    @Test("「内容を持たない」確率が 0.5 以上の発話は、平均に入れない。使える発話が 1 件も無ければ、ヒントは空")
    func fillerIsIgnored() async throws {
        let judge = FakeJudge()
        judge.probabilities = ["佐藤 花子": 0.9, "田中 美咲": 0.1]
        judge.filler = 0.9
        #expect(try await maker(judge).hints(for: ["はい、そうですね、お願いします"]).isEmpty)
        judge.filler = 0.49
        #expect(try await maker(judge).hints(for: ["はい、そうですね、お願いします"]).first?.name == "佐藤 花子")
    }

    @Test("6 文字未満の発言は使わない（モデルへ問わない）。問う発話は、最大 20 件")
    func shortAndLimit() async throws {
        let judge = FakeJudge()
        judge.probabilities = ["佐藤 花子": 0.7, "田中 美咲": 0.3]
        let texts = ["はい", "ええ"] + (1...25).map { "二十五件ある発言の、\($0) 番目です" }
        _ = try await maker(judge).hints(for: texts)
        #expect(judge.calls.count == SpeakerHintMaker.maxTexts, "短い 2 件は問わず、残りのうち先頭の 20 件だけ")
    }

    @Test("名乗りがあれば、その人を「名乗りあり」のヒントにする（モデルへは問わない）。名前が出た人は、その発話の候補から外す")
    func introductionAndMentions() async throws {
        let judge = FakeJudge()
        judge.probabilities = ["佐藤 花子": 0.6, "田中 美咲": 0.4]
        let introduced = try await maker(judge).hints(for: ["佐藤です。よろしくお願いします"])
        #expect(introduced == [SpeakerHint(name: "佐藤 花子", probability: nil, introduced: true)] && judge.calls.isEmpty)

        _ = try await maker(judge).hints(for: ["田中さん、データベースの件はどうですか"])
        #expect(judge.calls == [["佐藤 花子"]], "呼びかけられた田中さんは、この発話の話者ではない")
    }

    @Test("出席者でない人は、ヒントにも出ない")
    func absentPeopleAreExcluded() async throws {
        let attendance = Attendance()
        attendance.setPresent("田中 美咲", false)
        let judge = FakeJudge()
        judge.probabilities = ["佐藤 花子": 0.7, "田中 美咲": 0.3]
        let hints = try await maker(judge, attendance: attendance).hints(for: ["マイグレーションの話をします"])
        #expect(hints.map(\.name) == ["佐藤 花子"] && judge.calls == [["佐藤 花子"]])
        attendance.setPresent("佐藤 花子", false)
        #expect(try await maker(judge, attendance: attendance).hints(for: ["マイグレーションの話をします"]).isEmpty, "出席者がいなければ、空")
    }

    @Test("壊れた答え（候補の数と合わない）は、使わない")
    func malformedAnswersAreSkipped() async throws {
        let judge = FakeJudge()
        judge.malformed = true
        #expect(try await maker(judge).hints(for: ["マイグレーションの話をします"]).isEmpty)
    }

    @Test("話者の発話の本文：確定した「相手」の、その話者の発話だけ。長いものから、同じ長さなら早いほうから、上限まで")
    func speakerTexts() {
        var transcript = Transcript()
        func add(_ id: Int, _ text: String, _ start: Double, voice: Int?, final: Bool = true, speaker: Speaker = .others) {
            transcript.record(Utterance(id: id, speaker: speaker, text: text, isFinal: final, startedAt: start, endedAt: start + 1, voice: voice))
        }
        add(1, "ふつうの長さ", 0, voice: 1)
        add(2, "いちばん長い発言の本文です", 1, voice: 1)
        add(3, "同じ長さの発言です", 2, voice: 1)
        add(4, "同じ長さの別の発言", 3, voice: 1)
        add(5, "別の話者の発言", 4, voice: 2)
        add(6, "暫定の発言です", 5, voice: 1, final: false)
        add(7, "本人の発言です", 6, voice: nil, speaker: .you)
        #expect(transcript.speakerTexts(of: 1, limit: 3) == ["いちばん長い発言の本文です", "同じ長さの発言です", "同じ長さの別の発言"])
        #expect(transcript.speakerTexts(of: 1, limit: 99).count == 4 && transcript.speakerTexts(of: 3, limit: 5).isEmpty)
    }
}
