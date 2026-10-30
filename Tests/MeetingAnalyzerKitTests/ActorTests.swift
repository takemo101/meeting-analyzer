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

/// 決まった答えを返し、呼ばれ方を記録する偽の判断モデル。
private final class FakeJudge: SpeakerJudge, @unchecked Sendable {
    private let lock = NSLock()
    var cue = true
    /// `choose` が選ぶ名前（候補にいなければ、先頭）。
    var pick: String?
    private(set) var cueCalls = 0
    private(set) var candidateNames: [[String]] = []

    func hasCue(in utterance: String, among actors: [Actor]) async throws -> Bool {
        lock.withLock { cueCalls += 1 }
        return cue
    }

    func choose(for utterance: String, among candidates: [Actor]) async throws -> Int {
        lock.withLock { candidateNames.append(candidates.map(\.name)) }
        return candidates.firstIndex { $0.name == pick } ?? 0
    }
}

@Suite("SpeakerGuesser：規則は、モデルでなく、コードが決める")
struct SpeakerGuesserTests {
    private func guesser(_ judge: FakeJudge, _ text: String = sample) throws -> SpeakerGuesser {
        SpeakerGuesser(list: try list(text), judge: judge)
    }

    @Test("手がかりがある発言は、モデルが選んだ人。候補に、本人（マイクの人）は入らない")
    func choosesAmongOthers() async throws {
        let judge = FakeJudge()
        judge.pick = "田中 美咲"
        let actor = try await guesser(judge).guess("月末の締め処理に間に合うかが関心事です")
        #expect(actor?.name == "田中 美咲")
        #expect(judge.candidateNames == [["佐藤 花子", "田中 美咲"]])
    }

    @Test("名前を呼ばれた人・言及された人は、話者の候補から外す（呼びかけを、話者と取り違えない）")
    func excludesMentioned() async throws {
        let judge = FakeJudge()
        judge.pick = "佐藤 花子"
        let actor = try await guesser(judge).guess("田中さんが言っていた件は、APIで対応できます")
        #expect(actor?.name == "佐藤 花子")
        #expect(judge.cueCalls == 1)
        // 候補が 1 人になれば、選ぶ問いは要らない。
        #expect(judge.candidateNames.isEmpty)
    }

    @Test("姓だけの呼びかけ・敬称つきの呼ばれ方でも外す。2 人に共通の語では、外さない")
    func mentionVariants() async throws {
        let judge = FakeJudge()
        _ = try await guesser(judge).guess("佐藤様、来週のスケジュールを確認します")
        #expect(judge.candidateNames == [], "佐藤が外れて、田中だけが残る")
        let twins = "## 山田 一郎\n- 呼ばれ方: 一郎さん\n## 山田 二郎\n- 呼ばれ方: 二郎さん\n## 佐藤 花子\n"
        let second = FakeJudge()
        _ = try await guesser(second, twins).guess("山田さん、確認をお願いします")
        #expect(second.candidateNames == [["山田 一郎", "山田 二郎", "佐藤 花子"]], "「山田」は 2 人の共通の語なので、誰のことか決められない")
    }

    @Test("名乗り（「佐藤です」）は、その人。モデルを使わない。ただし、別の人の名前も呼んでいれば、名乗りだけでは決めない")
    func selfIntroduction() async throws {
        let judge = FakeJudge()
        let actor = try await guesser(judge).guess("佐藤です。よろしくお願いします")
        #expect(actor?.name == "佐藤 花子" && judge.cueCalls == 0 && judge.candidateNames.isEmpty)
        let named = try await guesser(judge).guess("佐藤です。田中さんに確認をお願いしました")
        #expect(named == nil || named?.name != "田中 美咲")
    }

    @Test("手がかりが無い発言（相づち・進行）は、付けない。短すぎる発言は、モデルへ問わない")
    func abstains() async throws {
        let judge = FakeJudge()
        judge.cue = false
        #expect(try await guesser(judge).guess("では、次の議題に進みましょう") == nil)
        #expect(judge.cueCalls == 1 && judge.candidateNames.isEmpty)
        #expect(try await guesser(judge).guess("そうですね") == nil)
        #expect(judge.cueCalls == 1, "短い発言は、問わない")
    }

    @Test("相手の側の人がいない一覧（本人だけ）では、何も付けない")
    func nobodyElse() async throws {
        let judge = FakeJudge()
        #expect(try await guesser(judge, "## 山田\n- 本人: はい\n").guess("優先順位を決めましょう") == nil)
        #expect(judge.cueCalls == 0)
    }
}

/// 決まった名前を付ける偽の部品で、会議（`LiveSession`）の流れを通す。
private struct Rig {
    let fake = FakeInputs()
    let sink = RecordingSink()
    let clock = TestClock()
    let notices = Notices()
    let store = SessionStore(root: tempURL("actors"))

    func session(labeler: SpeakerLabeler?, actors: ActorSource? = nil) -> LiveSession {
        let clock = self.clock, notices = self.notices
        return LiveSession(
            title: "テスト会議", speakers: [.you, .others], inputs: fake.inputs, sink: sink, store: store,
            clock: { clock.now }, tickInterval: .seconds(60), actors: actors, labeler: labeler, notify: { notices.add($0) }
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
        let seen = Seen()
        let labeler = SpeakerLabeler { speaker, text in
            seen.add("\(speaker.rawValue):\(text)")
            return speaker == .you ? ActorLabel(name: "山田 太郎", guessed: false) : ActorLabel(name: "佐藤 花子", guessed: true)
        }
        let session = rig.session(labeler: labeler, actors: actors)
        try await session.start()
        rig.fake.emit(.others, "APIの仕様を", final: false, 0, 1)
        rig.fake.emit(.others, "APIの仕様を共有します", final: true, 0, 2)
        rig.fake.emit(.you, "確認します", final: true, 3, 4)
        rig.clock.advance(65)
        let outcome = try await session.end(reason: .user)

        #expect(!seen.values.contains("others:APIの仕様を"), "暫定の文は、推定しない")
        guard case .started(_, _, _, _, _, let file)? = rig.sink.events.first else { Issue.record("no started"); return }
        #expect(file == "/work/ACTOR.md")
        let updates = rig.sink.batches.flatMap(\.updates)
        let others = try #require(updates.last { $0.source == "others" })
        #expect(others.speaker == "相手" && others.actor == "佐藤 花子" && others.actorGuessed == true)
        let you = try #require(updates.last { $0.source == "you" })
        #expect(you.speaker == "本人" && you.actor == "山田 太郎" && you.actorGuessed == false)
        let text = try String(contentsOfFile: try #require(outcome.transcriptPath), encoding: .utf8)
        #expect(text.contains("相手（推定: 佐藤 花子）: APIの仕様を共有します") && text.contains("本人（山田 太郎）: 確認します"))
        #expect(text.contains("アクター（ACTOR.md）: 山田 太郎（本人）、佐藤 花子、田中 美咲"))
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

        #expect(rig.notices.all.filter { $0 == .speakerGuessFailed }.count == 1)
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

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
}

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

    @Test("設定の保存：ACTOR.md のパスと推定の入り切りを覚える。絶対パスでない値は、無しに戻す")
    func preferences() throws {
        let defaults = try #require(UserDefaults(suiteName: "ma-actors-" + UUID().uuidString))
        var saved = CapturePreferences()
        saved.actorFile = "/work/ACTOR.md"
        saved.guessSpeakers = false
        saved.save(defaults)
        let loaded = CapturePreferences.load(defaults)
        #expect(loaded.actorFile == "/work/ACTOR.md" && loaded.guessSpeakers == false)
        defaults.set("relative/ACTOR.md", forKey: CapturePreferences.keys.actorFile)
        #expect(CapturePreferences.load(defaults).actorFile == nil)
        #expect(CapturePreferences.load(try #require(UserDefaults(suiteName: "ma-actors-" + UUID().uuidString))).guessSpeakers == true, "既定は、推定する")
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
