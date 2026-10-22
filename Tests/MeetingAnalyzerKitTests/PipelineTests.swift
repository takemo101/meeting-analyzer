import Foundation
import Testing
@testable import MeetingAnalyzerKit

/// 送られたものを記録するだけの窓口。`failOnBatch` 番目のバッチで失敗させられる。
final class RecordingSender: BridgeSending, @unchecked Sendable {
    private(set) var events: [String] = []
    private(set) var batches: [CaptionBatch] = []
    private(set) var ends: [EndEvent] = []
    var failOnBatch: Int?
    var healthError: BridgeError?

    func health() async throws {
        if let healthError { throw healthError }
    }

    func send(_ batch: CaptionBatch) async throws {
        if batch.sequence == failOnBatch { throw BridgeError.unreachable }
        batches.append(batch)
        events.append("batch\(batch.sequence)")
    }

    func send(_ end: EndEvent) async throws {
        ends.append(end)
        events.append("end")
    }
}

private func update(_ text: String, final: Bool = false, _ start: Double, _ end: Double) -> TranscriptionUpdate {
    TranscriptionUpdate(text: text, isFinal: final, start: start, end: end)
}

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ma-tests-" + UUID().uuidString, isDirectory: true)
}

@Suite("SessionPipeline: 更新 → バッチ → 終了の合図")
struct SessionPipelineTests {
    @Test("確定した発話の次の更新は、新しい発話。番号と版が正しく付く")
    func ids() async throws {
        let sender = RecordingSender()
        let pipeline = SessionPipeline(meetingId: "m", sender: sender, store: nil)
        try await pipeline.ingest(update("来週", 0, 1), speaker: .others)
        try await pipeline.ingest(update("来週のリリース", 0, 2), speaker: .others)
        try await pipeline.ingest(update("来週のリリースの件です。", final: true, 0, 3), speaker: .others)
        try await pipeline.ingest(update("はい", 4, 5), speaker: .others)
        try await pipeline.ingest(update("私は確認します", 4.5, 6), speaker: .you)
        try await pipeline.finish(reason: .user, at: 10)

        let updates = sender.batches.flatMap(\.updates)
        #expect(updates.map(\.messageId) == ["others-1", "others-2", "you-1"])
        #expect(updates.first?.transcript == "来週のリリースの件です。")
        #expect(updates.first?.version == 3, "同じ発話の更新は、版が増える")
    }

    @Test("静かになるまでは送らず、静かになってから届いた更新は、前の発話を混ぜずに先に送る")
    func quietGapSendsEarlierUtteranceAlone() async throws {
        let sender = RecordingSender()
        let pipeline = SessionPipeline(meetingId: "m", sender: sender, store: nil)
        try await pipeline.ingest(update("来週のリリース", final: true, 0, 1), speaker: .others)
        #expect(sender.batches.isEmpty, "1.2 秒たつまでは保留")
        try await pipeline.ingest(update("別の話題", 5, 6), speaker: .others)
        #expect(sender.batches.map { $0.updates.map(\.transcript) } == [["来週のリリース"]], "5 秒の沈黙のあとの更新は、前の発話と一緒にしない")
        try await pipeline.finish(reason: .user, at: 6)
        #expect(sender.batches.map { $0.updates.map(\.transcript) } == [["来週のリリース"], ["別の話題"]])
    }

    @Test("更新が来なくても、時間が進めば（tick）、静かになった発話を送る")
    func tickSendsAfterQuiet() async throws {
        let sender = RecordingSender()
        let pipeline = SessionPipeline(meetingId: "m", sender: sender, store: nil)
        try await pipeline.ingest(update("来週のリリース", 0, 1), speaker: .others)
        try await pipeline.tick(at: 2.1)
        #expect(sender.batches.isEmpty)
        try await pipeline.tick(at: 2.2)
        #expect(sender.batches.count == 1)
        try await pipeline.tick(at: 10)
        #expect(sender.batches.count == 1, "送るものがなければ、何も送らない")
    }

    @Test("途切れなく続く発話は、境界（新しい発話の開始）で、前の発話と一緒に送る")
    func boundaryDuringContinuousSpeech() async throws {
        let sender = RecordingSender()
        let pipeline = SessionPipeline(meetingId: "m", sender: sender, store: nil)
        try await pipeline.ingest(update("一つ目の発話", final: true, 0, 0.5), speaker: .others)
        try await pipeline.ingest(update("二つ目", 0.6, 1.0), speaker: .others)
        try await pipeline.ingest(update("二つ目の", 0.6, 2.0), speaker: .others)
        #expect(sender.batches.isEmpty, "境界はあるが、開始から 3 秒たっていない")
        try await pipeline.ingest(update("二つ目の発話", 0.6, 3.0), speaker: .others)
        #expect(sender.batches.count == 1)
        #expect(sender.batches.first?.updates.map(\.transcript) == ["一つ目の発話", "二つ目の"], "境界で出るのは、その時点までの本文。最新の更新は、次のバッチ")
    }

    @Test("終了で、未送信を出し切り、記録を書いてから、最後に終了の合図を送る")
    func finishOrdering() async throws {
        let sender = RecordingSender()
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let pipeline = SessionPipeline(meetingId: "定例", startedAt: start, sender: sender, store: SessionStore(root: root))
        try await pipeline.ingest(update("来週のリリースの件です", final: true, 0, 2), speaker: .others)
        try await pipeline.ingest(update("確認します", final: true, 3, 4), speaker: .you)
        let end = try await pipeline.finish(reason: .user, endedAt: start.addingTimeInterval(65), at: 4)

        #expect(sender.events.last == "end", "終了の合図は、最後の 1 回だけ")
        #expect(sender.ends.count == 1)
        #expect(sender.events.filter { $0 == "end" }.count == 1)
        #expect(end.batches == sender.batches.count)
        #expect(end.utterances == 2)
        #expect(end.durationSeconds == 65)
        let path = try #require(end.transcriptPath)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("相手: 来週のリリースの件です"))
        #expect(text.contains("あなた: 確認します"))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600, "記録は、利用者だけが読める")
        let directory = try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        #expect((directory[.posixPermissions] as? Int) == 0o700)
    }

    @Test("何も話されなかった会議でも、終了の合図は送る（記録のパスは無い）")
    func emptyMeeting() async throws {
        let sender = RecordingSender()
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = SessionPipeline(meetingId: "m", sender: sender, store: SessionStore(root: root))
        let end = try await pipeline.finish(reason: .silence, at: 0)
        #expect(sender.batches.isEmpty)
        #expect(sender.ends.count == 1)
        #expect(end.transcriptPath == nil)
        #expect(end.reason == "silence")
    }

    @Test("記録を書けなくても、終了の合図は、記録のパスなしで送る（会議の終わりは伝える）")
    func transcriptWriteFailure() async throws {
        let sender = RecordingSender()
        let pipeline = SessionPipeline(meetingId: "m", sender: sender, store: SessionStore(root: URL(fileURLWithPath: "/dev/null/nope")))
        try await pipeline.ingest(update("来週のリリースの件です", final: true, 0, 2), speaker: .others)
        let end = try await pipeline.finish(reason: .user, at: 2)
        #expect(end.transcriptPath == nil)
        #expect(end.utterances == 1)
        #expect(sender.ends.count == 1)
    }

    @Test("空白だけの更新は、無視する")
    func blankIsIgnored() async throws {
        let sender = RecordingSender()
        let pipeline = SessionPipeline(meetingId: "m", sender: sender, store: nil)
        try await pipeline.ingest(update("  \n", 0, 5), speaker: .others)
        let end = try await pipeline.finish(reason: .user, at: 5)
        #expect(end.utterances == 0)
        #expect(sender.batches.isEmpty)
    }

    @Test("ブリッジへの送信が失敗したら、そこで止まって、失敗が呼び出し側へ伝わる")
    func bridgeFailureStops() async {
        let sender = RecordingSender()
        sender.failOnBatch = 1
        let pipeline = SessionPipeline(meetingId: "m", sender: sender, store: nil)
        await #expect(throws: BridgeError.unreachable) {
            try await pipeline.ingest(update("一つ目", final: true, 0, 1), speaker: .others)
            try await pipeline.ingest(update("二つ目", final: true, 10, 11), speaker: .others)
        }
        #expect(sender.ends.isEmpty)
    }
}
