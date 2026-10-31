import Foundation
import Testing
@testable import MeetingAnalyzerKit

private let sample = """
# アクター

会議に出る人の一覧。

## 山田 太郎
- 役割: プロダクトマネージャー
- 呼ばれ方: 山田さん, PM
- 話題: 優先順位、スケジュール
- 本人: はい

## 佐藤 花子
- 役割: バックエンドのエンジニア
- 呼ばれ方: 佐藤さん
- 話題: API・データベース

## 田中 美咲
- 役割: 顧客の経理部長
- 呼ばれ方: 田中さん, 田中様
"""

private func list(_ text: String = sample) throws -> ActorList {
    try ActorList.parse(text).get()
}

@Suite("ACTOR.md：読み取り")
struct ActorListTests {
    @Test("「## 名前」の節ごとに、役割・呼ばれ方・話題・本人を読む。区切りは、「、」「,」。説明の文章は、読まない")
    func parsesSections() throws {
        let actors = try list().actors
        #expect(actors.map(\.name) == ["山田 太郎", "佐藤 花子", "田中 美咲"])
        #expect(actors[0].role == "プロダクトマネージャー" && actors[0].aliases == ["山田さん", "PM"] && actors[0].topics == ["優先順位", "スケジュール"] && actors[0].isSelf)
        #expect(actors[1].topics == ["API・データベース"] && !actors[1].isSelf)
        #expect(try list().selfActor?.name == "山田 太郎")
        #expect(try list().others.map(\.name) == ["佐藤 花子", "田中 美咲"])
        #expect(try list().summary == "山田 太郎（本人）、佐藤 花子、田中 美咲")
    }

    @Test("使えない項目は、止めずに、警告にする（知らない項目名・「本人」の値の誤り）。使える部分は、読む")
    func warnsAndContinues() throws {
        let parsed = try list("## 山田 太郎\n- 役職: 部長\n- 本人: たぶん\n- 役割: PM\n")
        #expect(parsed.actors == [Actor(name: "山田 太郎", role: "PM")])
        #expect(parsed.warnings.count == 2)
    }

    @Test("読めない一覧は、理由つきで断る：アクターが無い・同じ名前・本人が 2 人・多すぎる")
    func rejects() {
        #expect(ActorList.parse("# だけ\n説明") == .failure(.empty))
        #expect(ActorList.parse("## 山田\n## 山田\n") == .failure(.duplicate("山田")))
        #expect(ActorList.parse("## 山田\n- 本人: はい\n## 佐藤\n- 本人: yes\n") == .failure(.multipleSelf(["山田", "佐藤"])))
        let many = (1...13).map { "## 人\($0)\n" }.joined()
        #expect(ActorList.parse(many) == .failure(.tooMany(max: ActorList.maxActors)))
    }
}

/// 決まった確率を返し、呼ばれ方を記録する偽の判断モデル。
private final class FakeJudge: SpeakerJudge, @unchecked Sendable {
    private let lock = NSLock()
    /// 名前 → 確率（候補にいない名前は、無視。候補で、指定が無い人は 0）。候補が 1 人のときは、1。
    var probabilities: [String: Double] = [:]
    var filler = 0.0
    /// 候補の数と違う長さの答えを返す（壊れた判断モデル）。
    var malformed = false
    private(set) var calls: [[String]] = []

    func judge(utterance: String, candidates: [Actor]) async throws -> SpeakerJudgement {
        lock.withLock { calls.append(candidates.map(\.name)) }
        if malformed { return SpeakerJudgement(probabilities: [1], filler: 0) }
        let p = candidates.count == 1 ? [1.0] : candidates.map { probabilities[$0.name] ?? 0 }
        return SpeakerJudgement(probabilities: p, filler: filler)
    }
}

@Suite("SpeakerGuesser：規則は、モデルでなく、コードが決める")
struct SpeakerGuesserTests {
    private func guesser(_ judge: FakeJudge, _ text: String = sample, gate: SpeakerGate = SpeakerGate()) throws -> SpeakerGuesser {
        SpeakerGuesser(list: try list(text), judge: judge, gate: gate)
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
        let guesser = SpeakerGuesser(list: try list(), judge: judge, attendance: attendance)
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

/// 発言に含まれる言葉で、話者を決める偽の判断モデル（言葉が無ければ、確率は、均等＝確信度が足りない）。
private struct KeywordJudge: SpeakerJudge {
    let keywords: [String: [String]] = ["佐藤 花子": ["マイグレーション", "API", "データベース"], "田中 美咲": ["経理", "月末", "請求書"]]

    func judge(utterance: String, candidates: [Actor]) async throws -> SpeakerJudgement {
        let hit = candidates.map { c in keywords[c.name]?.contains { utterance.contains($0) } == true }
        guard hit.contains(true) else { return SpeakerJudgement(probabilities: Array(repeating: 1 / Double(candidates.count), count: candidates.count), filler: 0) }
        let others = Double(candidates.count - hit.filter { $0 }.count)
        let p = hit.map { $0 ? 0.97 / Double(hit.filter { $0 }.count) : 0.03 / max(1, others) }
        return SpeakerJudgement(probabilities: p, filler: 0)
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

    private func guesser() throws -> SpeakerGuesser { SpeakerGuesser(list: try list(), judge: KeywordJudge()) }

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
        let labeler = SpeakerLabeler(list: try list(), guesser: try guesser())
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

/// 決まった名前を付ける偽の部品で、会議（`LiveSession`）の流れを通す。
private struct Rig {
    let fake = FakeInputs()
    let sink = RecordingSink()
    let clock = TestClock()
    let notices = Collected<LiveSessionNotice>()
    let store = SessionStore(root: tempURL("actors"))

    func session(labeler: SpeakerLabeler?, actors: ActorSource? = nil) -> LiveSession {
        let clock = self.clock, notices = self.notices
        return LiveSession(
            title: "テスト会議", speakers: [.you, .others], inputs: fake.inputs, sink: sink, store: store,
            options: LiveSessionOptions(actors: actors, labeler: labeler, timing: LiveSessionTiming(clock: { clock.now }, tickInterval: .seconds(60))), notify: { notices.add($0) }
        )
    }
}

@Suite("アクターを、記録とエージェントへの転送に使う")
struct ActorFlowTests {
    private func source() throws -> ActorSource { ActorSource(list: try list(), file: "/work/ACTOR.md") }

    @Test("「本人」は、ACTOR.md の本人へ対応づけ（推定ではない）、「相手」の確定した発話だけを推定する。記録・字幕・開始の出来事に載る")
    func labelsReachRecordAndEvents() async throws {
        let rig = Rig()
        let actors = try source()
        let seen = Collected<String>()
        let labeler = SpeakerLabeler { speaker, text in
            seen.add("\(speaker.rawValue):\(text)")
            return [LabeledSegment(text: text, actor: speaker == .you ? ActorLabel(name: "山田 太郎", guessed: false) : ActorLabel(name: "佐藤 花子", guessed: true))]
        }
        let session = rig.session(labeler: labeler, actors: actors)
        try await session.start()
        rig.fake.emit(.others, "APIの仕様を", final: false, 0, 1)
        rig.fake.emit(.others, "APIの仕様を共有します", final: true, 0, 2)
        rig.fake.emit(.you, "確認します", final: true, 3, 4)
        rig.clock.advance(65)
        let outcome = try await session.end(reason: .user)

        #expect(!seen.values.contains("others:APIの仕様を"), "暫定の文は、推定しない")
        guard case .started(let start)? = rig.sink.events.first else { Issue.record("no started"); return }
        #expect(start.actorFile == "/work/ACTOR.md")
        let updates = rig.sink.batches.flatMap(\.updates)
        let others = try #require(updates.last { $0.source == "others" })
        #expect(others.speaker == "相手" && others.actor == "佐藤 花子" && others.actorGuessed == true)
        let you = try #require(updates.last { $0.source == "you" })
        #expect(you.speaker == "本人" && you.actor == "山田 太郎" && you.actorGuessed == false)
        let text = try String(contentsOfFile: try #require(outcome.transcriptPath), encoding: .utf8)
        #expect(text.contains("相手（推定: 佐藤 花子）: APIの仕様を共有します") && text.contains("本人（山田 太郎）: 確認します"))
        #expect(text.contains("アクター（ACTOR.md）: 山田 太郎（本人）、佐藤 花子、田中 美咲"))
    }

    @Test("1 つの発話に、2 人分の文が続いていれば、別の発話（別の id）に分かれ、それぞれに名前が付く。字幕・記録に、順に載る")
    func splitsAnUtteranceByActor() async throws {
        let rig = Rig()
        let guesser = SpeakerGuesser(list: try list(), judge: KeywordJudge())
        let session = rig.session(labeler: SpeakerLabeler(list: try list(), guesser: guesser), actors: try source())
        try await session.start()
        rig.fake.emit(.others, "経理としては、月末の締め処理が気になります。マイグレーションに三十分ほどかかります。", final: true, 10, 18)
        rig.clock.advance(65)
        let outcome = try await session.end(reason: .user)

        let others = rig.sink.batches.flatMap(\.updates).filter { $0.source == "others" && $0.isFinal }
        #expect(others.map(\.id) == ["others-1", "others-2"])
        #expect(others.map(\.actor) == ["田中 美咲", "佐藤 花子"] && others.allSatisfy { $0.actorGuessed == true })
        #expect(others.map(\.text) == ["経理としては、月末の締め処理が気になります。", "マイグレーションに三十分ほどかかります。"])
        #expect(others[0].timestamp < others[1].timestamp, "時刻は、文字数で按分して、順に並ぶ")
        #expect(outcome.utterances == 2)
        let text = try String(contentsOfFile: try #require(outcome.transcriptPath), encoding: .utf8)
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("[") }
        #expect(lines.count == 2 && lines[0].contains("相手（推定: 田中 美咲）") && lines[1].contains("相手（推定: 佐藤 花子）"))
    }

    @Test("推定が失敗したら、1 回だけ知らせ、以後は名前を付けない。文字起こしと転送は、続く")
    func guessFailureStopsGuessingOnly() async throws {
        let rig = Rig()
        let labeler = SpeakerLabeler { _, _ in throw SpeakerTestError.modelFailed }
        let session = rig.session(labeler: labeler, actors: try source())
        try await session.start()
        rig.fake.emit(.others, "最初の話題です", final: true, 0, 2)
        rig.fake.emit(.others, "次の話題です", final: true, 3, 5)
        rig.clock.advance(65)
        let outcome = try await session.end(reason: .user)

        #expect(rig.notices.values.filter { $0 == .speakerGuessFailed }.count == 1)
        #expect(outcome.utterances == 2)
        #expect(rig.sink.batches.flatMap(\.updates).allSatisfy { $0.actor == nil })
    }

    @Test("名前が付かない発話（相手のまま）の字幕には、actor の項目が無い（これまでの形のまま）")
    func unlabeledCaptionKeepsOldShape() throws {
        let plain = TranscriptEvent.captions(sessionId: UUID(), sequence: 1, utterances: [Utterance(id: 1, speaker: .others, text: "はい", isFinal: true, startedAt: 0)], sessionStart: Date())
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        let update = try #require((object["updates"] as? [[String: Any]])?.first)
        #expect(update["actor"] == nil && update["actorGuessed"] == nil)
        let decoded = try JSONDecoder().decode(TranscriptEvent.self, from: JSONEncoder().encode(plain))
        #expect(decoded == plain)
    }
}

private enum SpeakerTestError: Error { case modelFailed }

@Suite("ACTOR.md のファイル：大きさ・文字コード・書式を、読むときに一度だけ検査する")
struct ActorFileTests {
    private func write(_ data: Data) throws -> String {
        let url = tempURL("actor-file", ext: "md")
        try data.write(to: url)
        return url.path
    }

    @Test("読める・読めない（無い・大きすぎる・UTF-8 でない・書式の誤り）")
    func loads() throws {
        #expect(try ActorFile.load(path: write(Data(sample.utf8))).get().actors.count == 3)
        #expect(ActorFile.load(path: "/no/such/ACTOR.md") == .failure(.notReadable("/no/such/ACTOR.md")))
        guard case .failure(.tooLarge) = ActorFile.load(path: try write(Data(repeating: 0x61, count: ActorFile.maxBytes + 1))) else { Issue.record("大きすぎるファイルを断らない"); return }
        #expect(ActorFile.load(path: try write(Data([0xFF, 0xFE, 0x00]))) == .failure(.notUTF8))
        #expect(ActorFile.load(path: try write(Data("説明だけ".utf8))) == .failure(.invalid(.empty)))
    }

    @Test("設定の保存：ACTOR.md のパスと、判断モデルの ID を覚える。絶対パスでない値・知らないモデルは、無しに戻す")
    func preferences() throws {
        let defaults = try #require(UserDefaults(suiteName: "ma-actors-" + UUID().uuidString))
        var saved = CapturePreferences()
        saved.actorFile = "/work/ACTOR.md"
        saved.decisionModel = "tiny-jev-0.6b"
        saved.save(defaults)
        let loaded = CapturePreferences.load(defaults)
        #expect(loaded.actorFile == "/work/ACTOR.md" && loaded.decisionModel == "tiny-jev-0.6b")
        defaults.set("relative/ACTOR.md", forKey: CapturePreferences.keys.actorFile)
        #expect(CapturePreferences.load(defaults).actorFile == nil)
        defaults.set("no-such-model", forKey: CapturePreferences.keys.decisionModel)
        #expect(CapturePreferences.load(defaults).decisionModel == nil, "知らないモデルの ID は、推定しない")
        #expect(CapturePreferences.load(try #require(UserDefaults(suiteName: "ma-actors-" + UUID().uuidString))).decisionModel == nil, "既定は、推定しない")
    }

    @Test("最近の ACTOR.md：選んだものが先頭に来る（重複しない）。上限を超えた古いものは捨てる。外した人は、ファイルごとに覚える。壊れた値は、その項目だけ捨てる")
    func recentFilesAndAbsentActors() throws {
        var saved = CapturePreferences()
        for index in 0..<(CapturePreferences.maxActorFiles + 2) { saved.remember(actorFile: "/p\(index)/ACTOR.md") }
        saved.remember(actorFile: "/p5/ACTOR.md")
        #expect(saved.actorFiles.count == CapturePreferences.maxActorFiles)
        #expect(saved.actorFiles.first == "/p5/ACTOR.md" && saved.actorFiles.filter { $0 == "/p5/ACTOR.md" }.count == 1)
        #expect(!saved.actorFiles.contains("/p0/ACTOR.md"), "古いものから捨てる")

        saved.actorFile = "/p5/ACTOR.md"
        saved.setAbsent(["田中 美咲", "高橋 健"], for: "/p5/ACTOR.md")
        saved.setAbsent(["鈴木 一郎"], for: "/p1/ACTOR.md")
        let defaults = try #require(UserDefaults(suiteName: "ma-actors-" + UUID().uuidString))
        saved.save(defaults)
        #expect(CapturePreferences.load(defaults) == saved)
        saved.setAbsent([], for: "/p1/ACTOR.md")
        #expect(saved.absentActors["/p1/ACTOR.md"] == nil, "全員出席に戻したら、項目ごと消す")

        // 一覧の項目が無かった版の設定（選んでいる ACTOR.md だけ）を引き継ぐ。壊れた値は、その項目だけ捨てる。
        let old = try #require(UserDefaults(suiteName: "ma-actors-" + UUID().uuidString))
        old.set("/old/ACTOR.md", forKey: CapturePreferences.keys.actorFile)
        #expect(CapturePreferences.load(old).actorFiles == ["/old/ACTOR.md"])
        old.set(["/a/ACTOR.md", "relative/ACTOR.md", "/a/ACTOR.md"], forKey: CapturePreferences.keys.actorFiles)
        old.set(["/a/ACTOR.md": ["田中 美咲"], "relative": ["x"], "/b/ACTOR.md": []], forKey: CapturePreferences.keys.absentActors)
        let loaded = CapturePreferences.load(old)
        #expect(loaded.actorFiles == ["/old/ACTOR.md", "/a/ACTOR.md"], "選んでいるものが、先頭")
        #expect(loaded.absentActors == ["/a/ACTOR.md": ["田中 美咲"]])
    }
}

@Suite("CLI：actors check と replay --actors")
struct ActorCommandTests {
    @Test("引数を一度だけ検査する")
    func parses() {
        #expect(CommandParser.parse(["actors", "check", "ACTOR.md"]) == .success(.actorsCheck(file: "ACTOR.md")))
        for bad in [["actors"], ["actors", "check"], ["actors", "list", "a"], ["actors", "check", "a", "b"]] {
            guard case .failure(.usage) = CommandParser.parse(bad) else { Issue.record("\(bad) を断らない"); return }
        }
        guard case .success(.replay(let options)) = CommandParser.parse(["replay", "a.wav", "--actors", "ACTOR.md"]) else { Issue.record("parse failed"); return }
        #expect(options.actors == "ACTOR.md")
    }

    @Test("--attendees：名前を、「,」「、」で区切って渡す。--actors と一緒でなければ断る。ACTOR.md の相手の側に無い名前は、再生の前に断る（終了コード 2）")
    func attendees() async throws {
        guard case .success(.replay(let options)) = CommandParser.parse(["replay", "a.wav", "--actors", "ACTOR.md", "--attendees", "佐藤 花子、田中 美咲, "]) else { Issue.record("parse failed"); return }
        #expect(options.attendees == ["佐藤 花子", "田中 美咲"])
        guard case .success(.replay(let plain)) = CommandParser.parse(["replay", "a.wav", "--actors", "ACTOR.md"]) else { Issue.record("parse failed"); return }
        #expect(plain.attendees == nil)
        guard case .failure(.usage) = CommandParser.parse(["replay", "a.wav", "--attendees", "佐藤 花子"]) else { Issue.record("--actors なしを断らない"); return }

        let actors = tempURL("attendees-actors", ext: "md")
        try Data(sample.utf8).write(to: actors)
        let err = Collected<String>()
        let run = ReplayOptions(file: actors.path, speaker: .others, title: "m", locale: "ja_JP", hold: 0, wait: 0, actors: actors.path, attendees: ["高橋 健", "山田 太郎"])
        let code = await CLIRunner(environment: ["MEETING_ANALYZER_DATA_DIR": tempURL("attendees-data").path], out: { _ in }, err: { err.add($0) }).run(.replay(run))
        #expect(code == 2 && (err.values.first ?? "").contains("高橋 健") && (err.values.first ?? "").contains("山田 太郎"), "\(err.values)")
    }
}

@Suite("アクターを作る skill: 例が、実際に読めること")
struct ActorAuthoringSkillTests {
    private func skillText() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("skills/meeting-analyzer-actors/SKILL.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("skill の見出しがあり、完成例が、アプリと同じ規則で読める。書いてある上限（12 人・64 KB）が、実装と一致している")
    func exampleParses() throws {
        let text = try skillText()
        #expect(text.hasPrefix("---\nname: meeting-analyzer-actors\ndescription: "))
        let start = try #require(text.range(of: "```markdown\n"))
        let end = try #require(text.range(of: "\n```", range: start.upperBound..<text.endIndex))
        let list = try ActorList.parse(String(text[start.upperBound..<end.lowerBound])).get()
        #expect(list.actors.count == 4 && list.selfActor?.name == "山田 太郎" && list.warnings.isEmpty)
        #expect(text.contains("\(ActorList.maxActors) 人まで") && text.contains("\(ActorFile.maxBytes / 1024) KB まで"))
    }
}
