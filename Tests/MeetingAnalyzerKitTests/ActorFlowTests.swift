import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("アクターを、記録とエージェントへの転送に使う")
struct ActorFlowTests {
    private func source() throws -> ActorSource { ActorSource(list: try actorList(), file: "/work/ACTOR.md") }

    @Test("「本人」は、ACTOR.md の本人へ対応づけ（推定ではない）、「相手」の確定した発話だけを推定する。記録・字幕・開始の出来事に載る")
    func labelsReachRecordAndEvents() async throws {
        let rig = ActorRig()
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
        let rig = ActorRig()
        let guesser = SpeakerGuesser(list: try actorList(), judge: KeywordJudge())
        let session = rig.session(labeler: SpeakerLabeler(list: try actorList(), guesser: guesser), actors: try source())
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
        let rig = ActorRig()
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
