import Foundation
import Testing
@testable import MeetingAnalyzerKit

/// 出来事を記録するだけの受け口。
final class RecordingSink: EventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TranscriptEvent] = []

    func publish(_ event: TranscriptEvent) { lock.withLock { storage.append(event) } }

    var events: [TranscriptEvent] { lock.withLock { storage } }
    var kinds: [String] { events.map(\.kind) }
    /// 字幕のバッチ（順序どおり）。
    var batches: [(sequence: Int, updates: [CaptionUpdate])] {
        events.compactMap { if case .captions(_, let sequence, let updates, _) = $0 { return (sequence, updates) } else { return nil } }
    }
    var ends: [TranscriptEvent] { events.filter { $0.kind == "ended" } }
}

struct EndedInfo {
    let reason: String, batches: Int, utterances: Int, durationSeconds: Int, transcriptPath: String?

    init?(_ event: TranscriptEvent) {
        guard case .ended(_, _, let reason, _, _, let duration, let batches, let utterances, let path) = event else { return nil }
        self.reason = reason; self.batches = batches; self.utterances = utterances; self.durationSeconds = duration; self.transcriptPath = path
    }
}

private func update(_ text: String, final: Bool = false, _ start: Double, _ end: Double) -> TranscriptionUpdate {
    TranscriptionUpdate(text: text, isFinal: final, start: start, end: end)
}

private func temporaryRoot() -> URL {
    tempURL("tests")
}

@Suite("SessionPipeline: 更新 → バッチ → 終了の出来事")
struct SessionPipelineTests {
    @Test("確定した発話の次の更新は、新しい発話。番号と版が正しく付く")
    func ids() {
        let sink = RecordingSink()
        let pipeline = SessionPipeline(title: "m", sink: sink, store: nil)
        pipeline.ingest(update("来週", 0, 1), speaker: .others)
        pipeline.ingest(update("来週のリリース", 0, 2), speaker: .others)
        pipeline.ingest(update("来週のリリースの件です。", final: true, 0, 3), speaker: .others)
        pipeline.ingest(update("はい", 4, 5), speaker: .others)
        pipeline.ingest(update("私は確認します", 4.5, 6), speaker: .you)
        pipeline.finish(reason: .user, at: 10)

        let updates = sink.batches.flatMap(\.updates)
        #expect(updates.map(\.id) == ["others-1", "others-2", "you-1"])
        #expect(updates.first?.text == "来週のリリースの件です。")
        #expect(updates.first?.version == 3, "同じ発話の更新は、版が増える")
        #expect(updates.first?.isFinal == true)
    }

    @Test("静かになるまでは送らず、静かになってから届いた更新は、前の発話を混ぜずに先に送る")
    func quietGapSendsEarlierUtteranceAlone() {
        let sink = RecordingSink()
        let pipeline = SessionPipeline(title: "m", sink: sink, store: nil)
        pipeline.ingest(update("来週のリリース", final: true, 0, 1), speaker: .others)
        #expect(sink.batches.isEmpty, "1.2 秒たつまでは保留")
        pipeline.ingest(update("別の話題", 5, 6), speaker: .others)
        #expect(sink.batches.map { $0.updates.map(\.text) } == [["来週のリリース"]], "5 秒の沈黙のあとの更新は、前の発話と一緒にしない")
        pipeline.finish(reason: .user, at: 6)
        #expect(sink.batches.map { $0.updates.map(\.text) } == [["来週のリリース"], ["別の話題"]])
    }

    @Test("更新が来なくても、時間が進めば（tick）、静かになった発話を送る")
    func tickSendsAfterQuiet() {
        let sink = RecordingSink()
        let pipeline = SessionPipeline(title: "m", sink: sink, store: nil)
        pipeline.ingest(update("来週のリリース", 0, 1), speaker: .others)
        pipeline.tick(at: 2.1)
        #expect(sink.batches.isEmpty)
        pipeline.tick(at: 2.2)
        #expect(sink.batches.count == 1)
        pipeline.tick(at: 10)
        #expect(sink.batches.count == 1, "送るものがなければ、何も送らない")
    }

    @Test("途切れなく続く発話は、境界（新しい発話の開始）で、前の発話と一緒に送る")
    func boundaryDuringContinuousSpeech() {
        let sink = RecordingSink()
        let pipeline = SessionPipeline(title: "m", sink: sink, store: nil)
        pipeline.ingest(update("一つ目の発話", final: true, 0, 0.5), speaker: .others)
        pipeline.ingest(update("二つ目", 0.6, 1.0), speaker: .others)
        pipeline.ingest(update("二つ目の", 0.6, 2.0), speaker: .others)
        #expect(sink.batches.isEmpty, "境界はあるが、開始から 3 秒たっていない")
        pipeline.ingest(update("二つ目の発話", 0.6, 3.0), speaker: .others)
        #expect(sink.batches.count == 1)
        #expect(sink.batches.first?.updates.map(\.text) == ["一つ目の発話", "二つ目の"], "境界で出るのは、その時点までの本文。最新の更新は、次のバッチ")
    }

    @Test("バッチの番号は 1 から連続する")
    func sequences() {
        let sink = RecordingSink()
        let pipeline = SessionPipeline(title: "m", sink: sink, store: nil)
        pipeline.ingest(update("一つ目", final: true, 0, 1), speaker: .others)
        pipeline.ingest(update("二つ目", final: true, 10, 11), speaker: .others)
        pipeline.ingest(update("三つ目", final: true, 20, 21), speaker: .others)
        pipeline.finish(reason: .user, at: 21)
        #expect(sink.batches.map(\.sequence) == [1, 2, 3])
    }

    @Test("開始の出来事は、取り込む流れつきで、最初に 1 回。終了は最後に 1 回")
    func beginAndEnd() {
        let sink = RecordingSink()
        let pipeline = SessionPipeline(title: "定例", sink: sink, store: nil)
        pipeline.begin(sources: [.you, .others])
        pipeline.ingest(update("来週のリリース", final: true, 0, 1), speaker: .others)
        pipeline.finish(reason: .user, at: 1)
        #expect(sink.kinds == ["started", "captions", "ended"])
        guard case .started(let id, let title, _, let sources, _) = sink.events[0] else { Issue.record("not started"); return }
        #expect(id == pipeline.sessionId.uuidString.lowercased() && title == "定例" && sources == ["you", "others"])
    }

    @Test("終了で、未送信を出し切り、記録を書いてから、最後に終了の出来事を出す")
    func finishOrdering() throws {
        let sink = RecordingSink()
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let pipeline = SessionPipeline(title: "定例", startedAt: start, sink: sink, store: SessionStore(root: root))
        pipeline.ingest(update("来週のリリースの件です", final: true, 0, 2), speaker: .others)
        pipeline.ingest(update("確認します", final: true, 3, 4), speaker: .you)
        let end = try #require(EndedInfo(pipeline.finish(reason: .user, endedAt: start.addingTimeInterval(65), at: 4)))

        #expect(sink.kinds.last == "ended", "終了は、最後の 1 回だけ")
        #expect(sink.ends.count == 1)
        #expect(end.batches == sink.batches.count)
        #expect(end.utterances == 2)
        #expect(end.durationSeconds == 65)
        let path = try #require(end.transcriptPath)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("相手: 来週のリリースの件です"))
        #expect(text.contains("本人: 確認します"))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600, "記録は、利用者だけが読める")
        let directory = try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        #expect((directory[.posixPermissions] as? Int) == 0o700)
    }

    @Test("何も話されなくても、終了の出来事は出す（記録のパスは無い）")
    func emptySession() throws {
        let sink = RecordingSink()
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = SessionPipeline(title: "m", sink: sink, store: SessionStore(root: root))
        let end = try #require(EndedInfo(pipeline.finish(reason: .silence, at: 0)))
        #expect(sink.batches.isEmpty)
        #expect(sink.ends.count == 1)
        #expect(end.transcriptPath == nil)
        #expect(end.reason == "silence")
    }

    @Test("記録を書けなくても、終了の出来事は、記録のパスなしで出す（終わりは伝える）")
    func transcriptWriteFailure() throws {
        let sink = RecordingSink()
        let pipeline = SessionPipeline(title: "m", sink: sink, store: SessionStore(root: URL(fileURLWithPath: "/dev/null/nope")))
        pipeline.ingest(update("来週のリリースの件です", final: true, 0, 2), speaker: .others)
        let end = try #require(EndedInfo(pipeline.finish(reason: .user, at: 2)))
        #expect(end.transcriptPath == nil)
        #expect(end.utterances == 1)
        #expect(sink.ends.count == 1)
    }

    @Test("空白だけの更新は、無視する")
    func blankIsIgnored() throws {
        let sink = RecordingSink()
        let pipeline = SessionPipeline(title: "m", sink: sink, store: nil)
        pipeline.ingest(update("  \n", 0, 5), speaker: .others)
        let end = try #require(EndedInfo(pipeline.finish(reason: .user, at: 5)))
        #expect(end.utterances == 0)
        #expect(sink.batches.isEmpty)
    }
}
