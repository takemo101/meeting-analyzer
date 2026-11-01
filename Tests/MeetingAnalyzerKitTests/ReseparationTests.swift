import AVFoundation
import Foundation
import Testing
@testable import MeetingAnalyzerKit

private func tone(_ seconds: Double, rate: Double = 48_000) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.05)) * 0.5 }
    return buffer
}

private struct Stub: VoiceSeparating {
    var result: Result<VoiceSeparation, VoiceSeparationError>
    func separate(_ samples: [Float]) async throws -> VoiceSeparation { try result.get() }
}

private func separation(_ segments: [VoiceSegment], embeddings: [String: [Float]] = [:]) -> Stub {
    Stub(result: .success(VoiceSeparation(segments: segments, embeddings: embeddings)))
}

@Suite("聞き直し・分け直し：音声との対応（SPEC §3.16）")
struct SavedAudioPlaybackTests {
    @Test("会議の時刻の区間 → つなげた音声の中の区間。一時停止で分かれた塊ごとにずれる。塊の外・境をまたぐ区間は、重なる最初の塊の中だけ。長さには上限")
    func playbackMapping() {
        // 塊 1：会議の 10〜20 秒（音声の 0〜10 秒）。塊 2：会議の 100〜130 秒（音声の 10〜40 秒）。
        let timeline = AudioTimeline(pieces: [.init(origin: 10, duration: 10), .init(origin: 100, duration: 30)])
        #expect(timeline.playback(start: 12, end: 15)?.position == 2 && timeline.playback(start: 12, end: 15)?.duration == 3)
        #expect(timeline.playback(start: 105, end: 110)?.position == 15, "塊 2 は、音声の 10 秒から")
        #expect(timeline.playback(start: 18, end: 25)?.duration == 2, "塊 1 の終わりで切る")
        #expect(timeline.playback(start: 40, end: 50) == nil, "どの塊にも入らない（一時停止の間）")
        #expect(timeline.playback(start: 100, end: 130, limit: 5)?.duration == 5)
    }

    @Test("保存した音声を読み戻す：音と時刻の対応が合う。無い・壊れている（長さが合わない）ときは、理由を返す")
    func loadsAndRejectsBadFiles() throws {
        let root = tempURL("saved-load")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SavedAudioStore(root: root), id = UUID()
        guard case .failure(.missing) = store.load(sessionId: id) else { Issue.record("無いときは .missing"); return }

        let samples = (0..<(16_000 * 3)).map { Float(sin(Double($0) * 0.01)) * 0.4 }
        guard case .success = store.save(samples: samples, timeline: AudioTimeline(pieces: [.init(origin: 5, duration: 3)]), sessionId: id) else { Issue.record("save"); return }
        let loaded = try store.load(sessionId: id).get()
        #expect(loaded.samples.count == samples.count && loaded.timeline.pieces == [.init(origin: 5, duration: 3)])
        #expect(try store.timeline(sessionId: id).get().pieces.first?.origin == 5)

        // 時刻の対応を、音声の長さと合わないものに書き換える（壊れた保存）。
        try Data(#"{"sampleRate":16000,"pieces":[{"origin":0,"duration":30}]}"#.utf8).write(to: store.timelineURL(sessionId: id))
        guard case .failure(.unreadable) = store.load(sessionId: id) else { Issue.record("長さが合わないときは .unreadable"); return }
    }
}

@Suite("再分離：記録の書き直し・名前を外す・speakers の出来事（SPEC §3.16）")
@MainActor
struct ReseparationFlowTests {
    /// 2 つの発話（1〜5 秒・6〜10 秒）を持つ、終わった会議。初めの分離は、前半＝a・後半＝b。音声は保存する。
    private func endedSession(_ root: URL, library: VoiceprintLibrary? = nil, embeddings: [String: [Float]] = [:]) async throws -> (LiveSession, RecordingSink) {
        let fake = FakeInputs(), sink = RecordingSink(), clock = TestClock()
        let recorder = VoiceAudioRecorder()
        let inputs = LiveInputs { speaker in
            if speaker == .others { recorder.begin(); recorder.setOrigin(0); recorder.append(tone(12)) }
            return try await fake.inputs.open(speaker)
        }
        let first = separation([VoiceSegment(speaker: "a", start: 0, end: 5.5), VoiceSegment(speaker: "b", start: 5.5, end: 12)], embeddings: embeddings)
        let session = LiveSession(
            title: "テスト会議", speakers: [.others], inputs: inputs, sink: sink, store: SessionStore(root: root),
            options: LiveSessionOptions(timing: LiveSessionTiming(clock: { clock.now }, tickInterval: .seconds(60)), voice: LiveSessionVoice(recorder: recorder, separator: first, library: library, audioStore: SavedAudioStore(root: root))),
            notify: { _ in }
        )
        try await session.start()
        fake.emit(.others, "最初の人の話です", final: true, 1, 5)
        fake.emit(.others, "二人目の話です", final: true, 6, 10)
        clock.advance(65)
        _ = try await session.end(reason: .user)
        return (session, sink)
    }

    private func transcript(_ named: SpeakersNamed) throws -> String {
        try String(contentsOfFile: try #require(named.transcriptPath), encoding: .utf8)
    }

    @Test("再分離：話者 ID が付け直され、確定していた名前は外れ、記録が書き直される。speakers の出来事は、reseparated つきで、いまの名前のすべて（ここでは空）")
    func reapplies() async throws {
        let root = tempURL("reseparate")
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, sink) = try await endedSession(root)
        _ = try await session.nameSpeakers([2: "鈴木 一郎"]).get()
        #expect(await session.speakerNames() == [2: "鈴木 一郎"])

        // 分け直し：全員が 1 人（q）になる。
        let named = try await session.reseparate(audio: SavedAudioStore(root: root), separator: separation([VoiceSegment(speaker: "q", start: 0, end: 12)]), library: nil).get()
        #expect(named.reseparated == true && named.speakers.isEmpty)
        #expect(await session.speakerNames().isEmpty, "確定していた名前は、外れる")
        #expect(await session.speakerSummaries().map(\.id) == [1])
        let text = try transcript(named)
        #expect(text.contains("相手（話者 1）: 最初の人の話です") && text.contains("相手（話者 1）: 二人目の話です") && !text.contains("鈴木"))
        #expect(text.contains("話者（声）: 1 人（分離が見つけた話者: 1 人"))
        #expect(sink.kinds.suffix(2) == ["speakers", "speakers"], "名付けの出来事のあとに、再分離の出来事")
        guard case .speakers(let published)? = sink.events.last else { Issue.record("no speakers event"); return }
        #expect(published.reseparated == true)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(TranscriptEvent.speakers(published))) as? [String: Any])
        #expect(json["reseparated"] as? Bool == true)
    }

    @Test("再分離のあと、声紋の照合から、やり直す：自動の条件を満たす話者に、名前が付き、speakers に載る")
    func rematchesVoiceprints() async throws {
        let root = tempURL("reseparate-vp")
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, _) = try await endedSession(root)
        var library = VoiceprintLibrary(modelRevision: "test")
        try library.add(name: "佐藤 花子", vector: [1, 0, 0], now: Date())
        // 分け直し：q の声の特徴が、佐藤の声紋と同じ向き。
        let named = try await session.reseparate(audio: SavedAudioStore(root: root), separator: separation([VoiceSegment(speaker: "q", start: 0, end: 12)], embeddings: ["q": [1, 0, 0]]), library: library).get()
        #expect(named.speakers == [SpeakerName(speaker: 1, name: "佐藤 花子")])
        #expect(try transcript(named).contains("相手（佐藤 花子）: 最初の人の話です"))
    }

    @Test("失敗したら、何も変えない：分離に失敗・音声が無い。名前も記録も、そのまま。出来事も出ない")
    func failuresChangeNothing() async throws {
        let root = tempURL("reseparate-fail")
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, sink) = try await endedSession(root)
        _ = try await session.nameSpeakers([1: "佐藤"]).get()
        let before = sink.kinds

        // 分離に失敗
        let failing = Stub(result: .failure(.failed("GPU")))
        guard case .failure(.separation(let reason)) = await session.reseparate(audio: SavedAudioStore(root: root), separator: failing, library: nil) else { Issue.record("分離の失敗を返さない"); return }
        #expect(reason.contains("GPU"))
        // 音声が無い（別の置き場所）
        guard case .failure(.audio(.missing)) = await session.reseparate(audio: SavedAudioStore(root: tempURL("no-audio")), separator: separation([]), library: nil) else { Issue.record("音声が無いときの失敗を返さない"); return }

        #expect(await session.speakerNames() == [1: "佐藤"] && sink.kinds == before)
        let current = try String(contentsOfFile: try #require(await session.speakerSummaries().isEmpty ? nil : SessionStore(root: root).transcriptURL(sessionId: session.sessionId).path), encoding: .utf8)
        #expect(current.contains("相手（佐藤）: 最初の人の話です") && current.contains("相手（話者 2）: 二人目の話です"))
    }

    @Test("コントローラー：モデルが無ければ分け直せない。分け直すと、名前が外れ、話者の要約が替わり、状態が done になる（人数の指定は、分離器へ渡る）。範囲外の人数は、何もしない。次の会議の開始で手放す")
    func controllerReseparation() async throws {
        let root = tempURL("reseparate-controller")
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, _) = try await endedSession(root)
        let name = "ma-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = MeetingController(environment: ["MEETING_ANALYZER_DATA_DIR": root.path, "MEETING_ANALYZER_SOCKET": "/tmp/ma-\(UUID().uuidString.prefix(8)).sock"], defaults: defaults)
        controller.voiceSeparatorFactory = { _, _, tuning in
            // 人数の指定が、分離器へ渡ること：2 人なら 2 つ、自動なら 1 つ。
            tuning.speakerCount == 2
                ? separation([VoiceSegment(speaker: "x", start: 0, end: 3), VoiceSegment(speaker: "y", start: 3, end: 12)])
                : separation([VoiceSegment(speaker: "q", start: 0, end: 12)])
        }
        controller.namingSession = session
        controller.namingSpeakers = await session.speakerSummaries()
        #expect(controller.namingAudioAvailable && !controller.canReseparate, "モデルが未取得のあいだは、分け直せない")
        await controller.reseparateSpeakers(count: 2)
        #expect(controller.reseparation == .failed("話者の分離のモデルが、取得されていません"))

        // モデルを、取得済みに見せる。
        let store = ModelStore(root: root), model = VoiceModelCatalog.all[0]
        for artifact in model.artifacts {
            try store.prepareParent(of: artifact)
            FileManager.default.createFile(atPath: store.fileURL(artifact).path, contents: nil)
            let handle = try FileHandle(forWritingTo: store.fileURL(artifact))
            try handle.truncate(atOffset: UInt64(artifact.bytes))
            try handle.close()
            store.markVerified(artifact)
        }
        #expect(await controller.confirmSpeakerName(1, name: "佐藤").failure == nil)
        #expect(controller.canReseparate)

        await controller.reseparateSpeakers(count: 1)   // 範囲外は、何もしない
        #expect(controller.namedSpeakers == [1: "佐藤"])
        await controller.reseparateSpeakers(count: nil)
        #expect(controller.reseparation == .done(1) && controller.namedSpeakers.isEmpty && controller.namingSpeakers.map(\.id) == [1])
        await controller.reseparateSpeakers(count: 2)
        #expect(controller.reseparation == .done(2) && controller.namingSpeakers.map(\.id) == [1, 2])

        controller.clearNaming()
        #expect(controller.reseparation == .idle && controller.namingSession == nil)
    }
}
