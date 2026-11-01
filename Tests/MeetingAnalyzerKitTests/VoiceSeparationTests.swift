import AVFoundation
import Foundation
import Testing
@testable import MeetingAnalyzerKit

/// 48 kHz・モノラルの Float の音（`seconds` 秒）。
private func tone(_ seconds: Double, rate: Double = 48_000) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.05)) * 0.5 }
    return buffer
}

@Suite("声の分離：発話への話者 ID の付け方（SPEC §3.14）")
struct VoiceAssignmentTests {
    private func seg(_ speaker: String, _ start: Double, _ end: Double) -> VoiceSegment { VoiceSegment(speaker: speaker, start: start, end: end) }

    @Test("発話ごとに、最も長く重なる話者の ID。ID は、発話の出現の順に 1 から。同じ話者は、同じ ID")
    func numbersByFirstAppearance() {
        let segments = [seg("S9", 0, 5), seg("S2", 5, 12), seg("S9", 12, 20)]
        let result = VoiceAssignment.assign(spans: [(1, 4), (6, 11), (13, 18), (4, 7)], segments: segments)
        #expect(result.ids == [1, 2, 1, 2], "4〜7 は、S9 が 1 秒・S2 が 2 秒 → S2")
        #expect(result.count == 2)
    }

    @Test("重なりが無い発話は付けない（ID も数えない）。同じ長さなら、区間の開始が早い話者")
    func noOverlapAndTies() {
        let result = VoiceAssignment.assign(spans: [(30, 35), (4, 6)], segments: [seg("B", 0, 5), seg("A", 5, 10)])
        #expect(result.ids == [nil, 1] && result.count == 1, "4〜6 は、B が 1 秒・A が 1 秒の同点 → 開始が早い B（ID は 1）")
        #expect(VoiceAssignment.assign(spans: [(1, 2)], segments: []).ids == [nil])
    }

    @Test("一時停止をはさんだ音声：つなげた時刻の区間を、会議の時刻へ戻す。塊の境をまたぐ区間は、塊ごとに分ける")
    func timelineMapsBackAcrossPauses() {
        // 会議の 10〜20 秒（10 秒の塊）と、100〜110 秒（10 秒の塊）。つなげた音声は 20 秒。
        let timeline = AudioTimeline(pieces: [.init(origin: 10, duration: 10), .init(origin: 100, duration: 10)])
        let mapped = timeline.sessionSegments(from: [VoiceSegment(speaker: "S1", start: 5, end: 15)])
        #expect(mapped == [VoiceSegment(speaker: "S1", start: 15, end: 20), VoiceSegment(speaker: "S1", start: 100, end: 105)])
    }
}

@Suite("VoiceAudioRecorder：16 kHz・モノラルで、メモリ上だけに持つ")
struct VoiceAudioRecorderTests {
    @Test("48 kHz の音を、16 kHz へ変えて持つ（長さは、ほぼ同じ秒数）。塊ごとの時刻（origin）が、対応に付く。時刻の無い塊・空の塊は、除く")
    func convertsAndKeepsPieces() throws {
        let recorder = VoiceAudioRecorder()
        recorder.begin(); recorder.setOrigin(5)
        recorder.append(tone(2)); recorder.append(tone(1))
        recorder.begin()                                  // 時刻が付かない塊
        recorder.append(tone(1))
        recorder.begin(); recorder.setOrigin(60)
        recorder.append(tone(2))
        let captured = try #require(recorder.snapshot())
        #expect(captured.timeline.pieces.map(\.origin) == [5, 60])
        #expect(abs(captured.timeline.pieces[0].duration - 3) < 0.05 && abs(captured.timeline.pieces[1].duration - 2) < 0.05)
        #expect(abs(Double(captured.samples.count) / 16_000 - 5) < 0.1)
        #expect(captured.samples.allSatisfy { abs($0) <= 1 })
        recorder.reset()
        #expect(recorder.snapshot() == nil && recorder.seconds == 0, "捨てたあとは、何も残らない")
    }

    @Test("上限を超える分は持たない（isTruncated）")
    func truncatesAtTheLimit() {
        let recorder = VoiceAudioRecorder(maxSamples: 16_000 * 3)
        recorder.begin(); recorder.setOrigin(0)
        recorder.append(tone(2)); recorder.append(tone(2))
        #expect(recorder.isTruncated && abs(recorder.seconds - 3) < 0.01)
    }
}

@Suite("声の分離：記録・終了の出来事への反映")
struct VoiceTranscriptTests {
    private func pipeline(_ sink: RecordingSink, store: SessionStore) -> SessionPipeline {
        SessionPipeline(title: "会議", sink: sink, store: store)
    }

    @Test("確定した「相手」の発話だけに、話者 ID が付く（暫定・本人は付かない）。記録に「相手（話者 N）」・見出し・注記。ended に speakers")
    func appliesToFinalOthersOnly() throws {
        let sink = RecordingSink(), store = SessionStore(root: tempURL("voice"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let pipeline = pipeline(sink, store: store)
        pipeline.begin(sources: [.you, .others])
        pipeline.ingest(TranscriptionUpdate(text: "最初の話です", isFinal: true, start: 0, end: 4), speaker: .others)
        pipeline.ingest(TranscriptionUpdate(text: "次の人の話です", isFinal: true, start: 5, end: 9), speaker: .others)
        pipeline.ingest(TranscriptionUpdate(text: "本人の話です", isFinal: true, start: 1, end: 3), speaker: .you)
        pipeline.ingest(TranscriptionUpdate(text: "まだ途中", isFinal: false, start: 10, end: 11), speaker: .others)
        let count = pipeline.applyVoices([VoiceSegment(speaker: "x", start: 0, end: 4.5), VoiceSegment(speaker: "y", start: 4.5, end: 12)])
        #expect(count == 2)
        let end = pipeline.finish(reason: .user, endedAt: Date(), at: 12)
        #expect(end.speakers == 2)
        let text = try String(contentsOfFile: try #require(end.transcriptPath), encoding: .utf8)
        #expect(text.contains("相手（話者 1）: 最初の話です") && text.contains("相手（話者 2）: 次の人の話です"))
        #expect(text.contains("本人: 本人の話です") && text.contains("相手: まだ途中"), "本人・暫定の発話には、付かない")
        #expect(text.contains("- 話者（声）: 2 人") && text.contains("声の違いから分けた"))
        guard case .ended(let ended)? = sink.events.last else { Issue.record("no ended"); return }
        #expect(ended.speakers == 2)
    }

    @Test("話者 ID が付いた発話は、「相手（話者 2）」。分離していない会議の記録・終了の出来事は、これまでの形のまま")
    func labelAndOldShape() throws {
        var utterance = Utterance(id: 1, speaker: .others, text: "はい", isFinal: true, startedAt: 0, voice: 2)
        #expect(utterance.speakerLabel == "相手（話者 2）")
        utterance.voice = nil
        #expect(utterance.speakerLabel == "相手")
        let plain = SessionEnd(sessionId: UUID(), title: "t", reason: .user, startedAt: Date(), endedAt: Date(), batches: 0, utterances: 0, transcriptPath: nil)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        #expect(json["speakers"] == nil)
    }

    @Test("分離に失敗したら、ID は付かず、記録の見出しに理由が残る。終了は続く")
    func failureIsRecorded() throws {
        let sink = RecordingSink(), store = SessionStore(root: tempURL("voice"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let pipeline = pipeline(sink, store: store)
        pipeline.begin(sources: [.others])
        pipeline.ingest(TranscriptionUpdate(text: "話です", isFinal: true, start: 0, end: 3), speaker: .others)
        pipeline.noteVoiceFailure("モデルが無い")
        let end = pipeline.finish(reason: .user, endedAt: Date(), at: 3)
        let text = try String(contentsOfFile: try #require(end.transcriptPath), encoding: .utf8)
        #expect(end.speakers == nil && text.contains("話者（声）: 分けられませんでした（モデルが無い）") && !text.contains("話者 1"))
    }
}

private struct FakeSeparator: VoiceSeparating {
    let result: Result<[VoiceSegment], VoiceSeparationError>
    func separate(_ samples: [Float]) async throws -> VoiceSeparation { VoiceSeparation(segments: try result.get()) }
}

@Suite("声の分離：会議（LiveSession）の終了の手順")
struct VoiceLiveSessionTests {
    private struct Rig {
        let fake = FakeInputs(), sink = RecordingSink(), clock = TestClock(), notices = Collected<LiveSessionNotice>()
        let store = SessionStore(root: tempURL("voice-live"))
        let recorder: VoiceAudioRecorder

        init(maxSamples: Int = VoiceAudioRecorder.maxSeconds * 16_000) { recorder = VoiceAudioRecorder(maxSamples: maxSamples) }

        func session(_ separator: FakeSeparator, seconds: Double = 12) -> LiveSession {
            let clock = self.clock, notices = self.notices, recorder = self.recorder, fake = self.fake
            // 実機の入口（`DeviceInputs`）と同じに、相手の流れを開くとき、塊を始めて、音を足す。
            let inputs = LiveInputs { speaker in
                if speaker == .others { recorder.begin(); recorder.append(tone(seconds)) }
                return try await fake.inputs.open(speaker)
            }
            return LiveSession(
                title: "テスト会議", speakers: [.others], inputs: inputs, sink: sink, store: store,
                options: LiveSessionOptions(timing: LiveSessionTiming(clock: { clock.now }, tickInterval: .seconds(60)), voice: LiveSessionVoice(recorder: recorder, separator: separator)),
                notify: { notices.add($0) }
            )
        }
    }

    @Test("終了のとき、持っていた音声を分けて、確定した発話に話者 ID を付け、音声を捨てる。記録と ended に反映される")
    func separatesAtTheEnd() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.store.root) }
        let session = rig.session(FakeSeparator(result: .success([VoiceSegment(speaker: "a", start: 0, end: 5.5), VoiceSegment(speaker: "b", start: 5.5, end: 12)])))
        try await session.start()
        rig.fake.emit(.others, "最初の人の話です", final: true, 1, 5)
        rig.fake.emit(.others, "二人目の話です", final: true, 6, 10)
        rig.clock.advance(65)
        let outcome = try await session.end(reason: .user)

        let text = try String(contentsOfFile: try #require(outcome.transcriptPath), encoding: .utf8)
        #expect(text.contains("相手（話者 1）: 最初の人の話です") && text.contains("相手（話者 2）: 二人目の話です"))
        guard case .ended(let ended)? = rig.sink.events.last else { Issue.record("no ended"); return }
        #expect(ended.speakers == 2)
        #expect(rig.recorder.snapshot() == nil && rig.recorder.seconds == 0, "音声は、終了のあと、残らない")
        #expect(rig.sink.batches.flatMap(\.updates).allSatisfy { $0.actor == nil }, "字幕（すでに送った出来事）には、話者 ID は付かない")
    }

    @Test("分離に失敗しても、会議は終わる：ID なしで記録を書き、1 回だけ知らせ、記録に理由が残る。音声は、捨てる")
    func failureDoesNotBreakTheEnd() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.store.root) }
        let session = rig.session(FakeSeparator(result: .failure(.failed("GPU"))))
        try await session.start()
        rig.fake.emit(.others, "話です", final: true, 1, 5)
        rig.clock.advance(65)
        let outcome = try await session.end(reason: .user)
        #expect(outcome.utterances == 1)
        let text = try String(contentsOfFile: try #require(outcome.transcriptPath), encoding: .utf8)
        #expect(!text.contains("話者 1") && text.contains("話者（声）: 分けられませんでした"))
        #expect(rig.notices.values.filter { if case .voiceSeparationFailed = $0 { return true } else { return false } }.count == 1)
        #expect(rig.recorder.seconds == 0)
    }

    @Test("上限を超えた長い会議は、最初の分だけを分け、1 回だけ知らせる")
    func truncationIsReported() async throws {
        let rig = Rig(maxSamples: 16_000 * 5)
        defer { try? FileManager.default.removeItem(at: rig.store.root) }
        let session = rig.session(FakeSeparator(result: .success([VoiceSegment(speaker: "a", start: 0, end: 5)])))
        try await session.start()
        rig.fake.emit(.others, "最初の話です", final: true, 1, 4)
        rig.clock.advance(65)
        _ = try await session.end(reason: .user)
        #expect(rig.notices.values.contains(.voiceSeparationTruncated))
    }
}

@Suite("CLI：replay --separate")
struct ReplaySeparateOptionTests {
    @Test("--separate は、値を取らないオプション。どこに置いてもよい。無指定は、分離しない。本人（--speaker you）とは、使えない")
    func parsesFlag() {
        guard case .success(.replay(let plain)) = CommandParser.parse(["replay", "a.wav"]) else { Issue.record("parse failed"); return }
        #expect(!plain.separate)
        guard case .success(.replay(let first)) = CommandParser.parse(["replay", "a.wav", "--separate", "--hold", "5"]) else { Issue.record("parse failed"); return }
        #expect(first.separate && first.hold == 5)
        guard case .success(.replay(let last)) = CommandParser.parse(["replay", "--separate", "a.wav"]) else { Issue.record("parse failed"); return }
        #expect(last.separate && last.file == "a.wav")
        guard case .failure(.usage) = CommandParser.parse(["replay", "a.wav", "--speaker", "you", "--separate"]) else { Issue.record("本人との組み合わせを断らない"); return }
        guard case .failure(.usage) = CommandParser.parse(["replay", "a.wav", "--separate", "--separate"]) else { Issue.record("重複を断らない"); return }
    }
}
