import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("SpeakerGuesser：規則は、モデルでなく、コードが決める")
struct SpeakerGuesserTests {
    private func guesser(_ judge: FakeJudge, _ text: String = actorSample, gate: SpeakerGate = SpeakerGate()) throws -> SpeakerGuesser {
        SpeakerGuesser(list: try actorList(text), judge: judge, gate: gate)
    }

    @Test("確信度が足りたときだけ付ける。候補に、本人（マイクの人）は入らない")
    func confidenceGate() async throws {
        let judge = FakeJudge()
        judge.probabilities = ["田中 美咲": 0.95, "佐藤 花子": 0.05]
        let actor = try await guesser(judge).guess("月末の締め処理に間に合うかが関心事です")
        #expect(actor?.name == "田中 美咲")
        #expect(judge.calls == [["佐藤 花子", "田中 美咲"]])
        judge.probabilities = ["田中 美咲": 0.6, "佐藤 花子": 0.4]
        #expect(try await guesser(judge).guess("月末の締め処理に間に合うかが関心事です") == nil, "確信度が、足りない")
        #expect(try await guesser(judge, gate: SpeakerGate(minimumConfidence: 0.55)).guess("月末の締め処理に間に合うかが関心事です")?.name == "田中 美咲", "しきい値は、設定できる")
    }

    @Test("内容を持たない発言（相づち・進行）は、付けない")
    func fillerIsNotLabeled() async throws {
        let judge = FakeJudge()
        judge.probabilities = ["田中 美咲": 0.97, "佐藤 花子": 0.03]
        judge.filler = 0.8
        #expect(try await guesser(judge).guess("では、次の議題に進みましょう") == nil)
        judge.filler = 0.49
        #expect(try await guesser(judge).guess("では、次の議題に進みましょう")?.name == "田中 美咲")
    }

    @Test("名前を呼ばれた人・言及された人は、話者の候補から外す（呼びかけを、話者と取り違えない）。1 人になっても、判断モデルの確認は通す")
    func excludesMentioned() async throws {
        let judge = FakeJudge()
        let actor = try await guesser(judge).guess("田中さんが言っていた件は、APIで対応できます")
        #expect(actor?.name == "佐藤 花子")
        #expect(judge.calls == [["佐藤 花子"]])
        judge.filler = 0.9
        #expect(try await guesser(judge).guess("田中さんが言っていた件は、APIで対応できます") == nil, "残りが 1 人でも、内容を持たない発言には、付けない")
    }

    @Test("姓だけの呼びかけ・敬称つきの呼ばれ方でも外す。2 人に共通の語では、外さない")
    func mentionVariants() async throws {
        let judge = FakeJudge()
        _ = try await guesser(judge).guess("佐藤様、来週のスケジュールを確認します")
        #expect(judge.calls == [["田中 美咲"]], "佐藤が外れて、田中だけが残る")
        let twins = "## 山田 一郎\n- 呼ばれ方: 一郎さん\n## 山田 二郎\n- 呼ばれ方: 二郎さん\n## 佐藤 花子\n"
        let second = FakeJudge()
        _ = try await guesser(second, twins).guess("山田さん、確認をお願いします")
        #expect(second.calls == [["山田 一郎", "山田 二郎", "佐藤 花子"]], "「山田」は 2 人の共通の語なので、誰のことか決められない")
    }

    @Test("名乗り（「佐藤です」）は、その人。モデルを使わない。ただし、別の人の名前も呼んでいれば、名乗りだけでは決めない")
    func selfIntroduction() async throws {
        let judge = FakeJudge()
        let actor = try await guesser(judge).guess("佐藤です。よろしくお願いします")
        #expect(actor?.name == "佐藤 花子" && judge.calls.isEmpty)
        let named = try await guesser(judge).guess("佐藤です。田中さんに確認をお願いしました")
        #expect(named == nil || named?.name != "田中 美咲")
    }

    @Test("短すぎる発言は、モデルへ問わない。相手の側の人がいない一覧（本人だけ）では、何も付けない。壊れた答え（候補の数と違う）は、付けない")
    func guards() async throws {
        let judge = FakeJudge()
        #expect(try await guesser(judge).guess("そうですね") == nil)
        #expect(try await guesser(judge, "## 山田\n- 本人: はい\n").guess("優先順位を決めましょう") == nil)
        #expect(judge.calls.isEmpty)
        judge.malformed = true
        #expect(try await guesser(judge).guess("月末の締め処理に間に合うかが関心事です") == nil)
    }

    @Test("出席者から外した人は、話者の候補にしない。会議の途中で変えると、次の判断から効く。相手の側の全員を外すと、判断しない")
    func attendance() async throws {
        let judge = FakeJudge()
        let attendance = Attendance()
        let guesser = SpeakerGuesser(list: try actorList(), judge: judge, attendance: attendance)
        let text = "月末の締め処理に間に合うかが関心事です"
        _ = try await guesser.guess(text)
        attendance.setPresent("田中 美咲", false)
        _ = try await guesser.guess(text)
        attendance.setPresent("田中 美咲", true)
        attendance.setPresent("佐藤 花子", false)
        _ = try await guesser.guess(text)
        #expect(judge.calls == [["佐藤 花子", "田中 美咲"], ["佐藤 花子"], ["田中 美咲"]])
        attendance.setPresent("田中 美咲", false)
        #expect(try await guesser.guess(text) == nil)
        #expect(judge.calls.count == 3, "候補がいなければ、判断モデルへ問わない")
    }
}

@Suite("文の分割と、話者ごとの区間への分割（SPEC §3.13）")
struct SpeakerSegmentTests {
    @Test("文は、「。」「！」「？」「…」と改行で切る。終わりの記号・閉じ括弧は、その文に含める。記号が無ければ、1 文")
    func sentenceSplitting() {
        #expect(SentenceSplitter.split("来週です。確認します！本当ですか？はい") == ["来週です。", "確認します！", "本当ですか？", "はい"])
        #expect(SentenceSplitter.split("「できます。」と言いました。次です") == ["「できます。」", "と言いました。", "次です"])
        #expect(SentenceSplitter.split("えっ？！そうなんですか…本当に") == ["えっ？！", "そうなんですか…", "本当に"])
        #expect(SentenceSplitter.split("1 行目\n2 行目\n\n  ") == ["1 行目", "2 行目"])
        #expect(SentenceSplitter.split("記号の無い本文です") == ["記号の無い本文です"])
        #expect(SentenceSplitter.split("   ") == [])
        let text = "月末の締め処理です。マイグレーションをします。"
        #expect(SentenceSplitter.split(text).joined() == text, "つなぐと、元の本文")
    }

    private func guesser() throws -> SpeakerGuesser { SpeakerGuesser(list: try actorList(), judge: KeywordJudge()) }

    @Test("確信をもって判断された、隣り合う文の話者が別の人のところで、区切る。同じ人の文は、まとまる")
    func splitsWhereTheSpeakerChanges() async throws {
        let two = try await guesser().segments("経理としては、月末の締め処理が気になります。マイグレーションに三十分ほどかかります。")
        #expect(two.map(\.actor?.name) == ["田中 美咲", "佐藤 花子"])
        #expect(two.map(\.text).joined() == "経理としては、月末の締め処理が気になります。マイグレーションに三十分ほどかかります。")
        let same = try await guesser().segments("経理としては、月末の締め処理が気になります。請求書の確認も済みました。")
        #expect(same.count == 1 && same[0].actor?.name == "田中 美咲")
    }

    @Test("判断されなかった文（相づち・短い文）は、前の区間に付く。先頭なら、最初に判断された区間に付く")
    func unlabeledSentencesAttach() async throws {
        let trailing = try await guesser().segments("経理としては、月末の締め処理が気になります。そうですね。")
        #expect(trailing.count == 1 && trailing[0].actor?.name == "田中 美咲" && trailing[0].text.hasSuffix("そうですね。"))
        let leading = try await guesser().segments("ええと。マイグレーションに三十分ほどかかります。経理としては、月末の締め処理が気になります。")
        #expect(leading.map(\.actor?.name) == ["佐藤 花子", "田中 美咲"] && leading[0].text.hasPrefix("ええと。"))
    }

    @Test("どの文も判断されなければ、本文全体で、もう一度判断する。文が 1 つなら、そのまま判断する")
    func fallbacks() async throws {
        let none = try await guesser().segments("そうですね。わかりました。")
        #expect(none.count == 1 && none[0].actor == nil && none[0].text == "そうですね。わかりました。")
        let single = try await guesser().segments("マイグレーションに三十分ほどかかります。")
        #expect(single.count == 1 && single[0].actor?.name == "佐藤 花子")
    }

    @Test("更新を区間ごとに分けるとき、元の時刻（開始〜終了）を、文字数で按分して、切れ目なくつなぐ。1 区間のもの・暫定の更新・本人は、分けない")
    func timeAllocation() async throws {
        let labeler = SpeakerLabeler(list: try actorList(), guesser: try guesser())
        let update = TranscriptionUpdate(text: "経理の月末の件です。マイグレーションの件です。", isFinal: true, start: 10, end: 20)
        let parts = try await labeler.split(update, speaker: .others)
        #expect(parts.count == 2)
        #expect(parts[0].update.start == 10 && parts[1].update.end == 20 && parts[0].update.end == parts[1].update.start)
        let boundary = 10 + 10.0 * Double(parts[0].update.text.count) / Double(update.text.count)
        #expect(abs(parts[0].update.end - boundary) < 1e-9, "切れ目は、文字数の割合")
        #expect(parts.allSatisfy { $0.update.isFinal })
        let partial = TranscriptionUpdate(text: update.text, isFinal: false, start: 10, end: 20)
        let unsplit = try await labeler.split(partial, speaker: .others)
        #expect(unsplit.count == 1 && unsplit[0].update == partial && unsplit[0].actor == nil)
        let mine = try await labeler.split(update, speaker: .you)
        #expect(mine.count == 1 && mine[0].update == update && mine[0].actor == ActorLabel(name: "山田 太郎", guessed: false))
    }
}
