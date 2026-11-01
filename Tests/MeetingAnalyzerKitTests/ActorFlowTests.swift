import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("アクターを、記録とエージェントへの転送に使う")
struct ActorFlowTests {
    private func source() throws -> ActorSource { ActorSource(list: try actorList(), file: "/work/ACTOR.md") }

    @Test("「本人」は、ACTOR.md の本人の名前が付く。「相手」は、会議の最中には、名前が付かない（字幕にも記録にも、推定の名前が出ない）。記録・字幕・開始の出来事に載る")
    func selfNameReachesRecordAndEvents() async throws {
        let rig = ActorRig()
        let session = rig.session(actors: try source())
        try await session.start()
        rig.fake.emit(.others, "APIの仕様を共有します", final: true, 0, 2)
        rig.fake.emit(.you, "確認します", final: true, 3, 4)
        rig.clock.advance(65)
        let outcome = try await session.end(reason: .user)

        guard case .started(let start)? = rig.sink.events.first else { Issue.record("no started"); return }
        #expect(start.actorFile == "/work/ACTOR.md")
        let updates = rig.sink.batches.flatMap(\.updates)
        let others = try #require(updates.last { $0.source == "others" })
        #expect(others.speaker == "相手" && others.actor == nil)
        let you = try #require(updates.last { $0.source == "you" })
        #expect(you.speaker == "本人" && you.actor == "山田 太郎")
        let text = try String(contentsOfFile: try #require(outcome.transcriptPath), encoding: .utf8)
        #expect(text.contains("相手: APIの仕様を共有します") && text.contains("本人（山田 太郎）: 確認します"))
        #expect(text.contains("アクター（ACTOR.md）: 山田 太郎（本人）、佐藤 花子、田中 美咲"))
        #expect(!text.contains("推定"), "会議の最中の推定は、しない")
    }

    @Test("1 つの発話に、2 人分の文が続いていても、会議の最中は、分けない（声で分ける場合は、会議の終了のとき。§3.14）")
    func utterancesAreNotSplit() async throws {
        let rig = ActorRig()
        let session = rig.session(actors: try source())
        try await session.start()
        rig.fake.emit(.others, "経理としては、月末の締め処理が気になります。マイグレーションに三十分ほどかかります。", final: true, 10, 18)
        rig.clock.advance(65)
        let outcome = try await session.end(reason: .user)
        let others = rig.sink.batches.flatMap(\.updates).filter { $0.source == "others" && $0.isFinal }
        #expect(others.map(\.id) == ["others-1"] && outcome.utterances == 1)
    }

    @Test("ACTOR.md が無い会議では、「本人」にも名前は付かない。名前が付かない発話（相手のまま）の字幕には、actor の項目が無い（これまでの形のまま）")
    func noActorsKeepsOldShape() async throws {
        let rig = ActorRig()
        let session = rig.session(actors: nil)
        try await session.start()
        rig.fake.emit(.you, "確認します", final: true, 3, 4)
        rig.clock.advance(65)
        _ = try await session.end(reason: .user)
        #expect(rig.sink.batches.flatMap(\.updates).allSatisfy { $0.actor == nil })

        let plain = TranscriptEvent.captions(sessionId: UUID(), sequence: 1, utterances: [Utterance(id: 1, speaker: .others, text: "はい", isFinal: true, startedAt: 0)], sessionStart: Date())
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        let update = try #require((object["updates"] as? [[String: Any]])?.first)
        #expect(update["actor"] == nil && update["actorGuessed"] == nil)
        #expect(try JSONDecoder().decode(TranscriptEvent.self, from: JSONEncoder().encode(plain)) == plain)
    }
}
