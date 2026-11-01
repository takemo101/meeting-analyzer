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
    var segments: [VoiceSegment]
    var embeddings: [String: [Float]] = [:]
    func separate(_ samples: [Float]) async throws -> VoiceSeparation { VoiceSeparation(segments: segments, embeddings: embeddings) }
}

private func permissions(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

/// 2 つの発話（1〜5 秒・6〜10 秒）と、「本人」の発話を持つ、終わった会議。初めの分離は、前半＝a・後半＝b。
@MainActor
private func endedMeeting(_ root: URL, saveAudio: Bool = true, revision: String = "rev1", sink: RecordingSink = RecordingSink()) async throws -> (session: LiveSession, sink: RecordingSink) {
    let fake = FakeInputs(), clock = TestClock()
    let recorder = VoiceAudioRecorder()
    let inputs = LiveInputs { speaker in
        if speaker == .others { recorder.begin(); recorder.setOrigin(0); recorder.append(tone(12)) }
        return try await fake.inputs.open(speaker)
    }
    let separator = Stub(segments: [VoiceSegment(speaker: "a", start: 0, end: 5.5), VoiceSegment(speaker: "b", start: 5.5, end: 12)], embeddings: ["a": [1, 0, 0], "b": [0, 1, 0]])
    let session = LiveSession(
        title: "週次の定例", speakers: [.you, .others], inputs: inputs, sink: sink, store: SessionStore(root: root),
        options: LiveSessionOptions(timing: LiveSessionTiming(clock: { clock.now }, tickInterval: .seconds(60)), voice: LiveSessionVoice(recorder: recorder, separator: separator, audioStore: saveAudio ? SavedAudioStore(root: root) : nil, modelRevision: revision)),
        notify: { _ in }
    )
    try await session.start()
    fake.emit(.others, "最初の人の話です", final: true, 1, 5)
    fake.emit(.you, "分かりました", final: true, 5.2, 5.9)
    fake.emit(.others, "二人目の話です", final: true, 6, 10)
    clock.advance(65)
    _ = try await session.end(reason: .user)
    return (session, sink)
}

@Suite("あとからの名付け：名付けの写し（speakers.json）の書き方・戻し方（SPEC §3.16）")
@MainActor
struct SessionSnapshotTests {
    @Test("音声を保存した会議の終了で、写しが 0600 で書かれる。保存しない会議・保存に失敗した会議には、書かれない。写しに、音声の中身は無い")
    func writtenOnlyWhenAudioIsSaved() async throws {
        let saved = tempURL("snap-saved"), unsaved = tempURL("snap-unsaved")
        defer { try? FileManager.default.removeItem(at: saved); try? FileManager.default.removeItem(at: unsaved) }
        let (session, _) = try await endedMeeting(saved)
        let store = SavedAudioStore(root: saved)
        #expect(FileManager.default.fileExists(atPath: store.snapshotURL(sessionId: session.sessionId).path) && permissions(store.snapshotURL(sessionId: session.sessionId)) == 0o600)
        let snapshot = try store.readSnapshot(sessionId: session.sessionId).get()
        #expect(snapshot.modelRevision == "rev1" && snapshot.utterances.count == 3 && snapshot.embeddings.keys.sorted() == ["1", "2"])

        let (other, _) = try await endedMeeting(unsaved, saveAudio: false)
        #expect(!FileManager.default.fileExists(atPath: SavedAudioStore(root: unsaved).snapshotURL(sessionId: other.sessionId).path))
    }

    @Test("写しから戻した記録の書き方は、元と同じ（本人の発話・見出し・話者 ID・確定した名前）")
    func roundTripKeepsTheTranscript() async throws {
        let root = tempURL("snap-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, _) = try await endedMeeting(root)
        let original = try String(contentsOf: SessionStore(root: root).transcriptURL(sessionId: session.sessionId), encoding: .utf8)
        let snapshot = try SavedAudioStore(root: root).readSnapshot(sessionId: session.sessionId).get()
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        let rebuilt = snapshot.makeTranscript().markdown(title: snapshot.title, startedAt: snapshot.startedDate, endedAt: snapshot.endedDate)
        // 開始・終了の時刻は、ISO 8601（秒まで）で書くので、同じ文字列になる。
        #expect(rebuilt == original, "戻した記録が、元と違う")
        #expect(original.contains("本人: 分かりました") && original.contains("相手（話者 1）") && original.contains("相手（話者 2）"))
    }

    @Test("過去の会議を戻して名付ける：要約が同じ。確定すると、記録が書き直され（本人の発話は残る）、speakers が、その会議の sessionId で出る。写しにも残り、もう一度戻しても、確定済み")
    func namingARestoredMeeting() async throws {
        let root = tempURL("snap-naming")
        defer { try? FileManager.default.removeItem(at: root) }
        let (live, _) = try await endedMeeting(root)
        let liveSummaries = await live.speakerSummaries()
        let store = SavedAudioStore(root: root)
        let sink = RecordingSink()

        let restored = try #require(RestoredSession(snapshot: try store.readSnapshot(sessionId: live.sessionId).get(), sink: sink, store: SessionStore(root: root), currentModelRevision: "rev1", library: nil))
        #expect(await restored.speakerSummaries() == liveSummaries)
        #expect(await restored.voiceEmbedding(of: 1) == [1, 0, 0], "同じ版なら、声の特徴を使える")

        let named = try await restored.nameSpeakers([2: "鈴木 一郎"]).get()
        #expect(named.sessionId == live.sessionId.uuidString.lowercased() && named.speakers == [SpeakerName(speaker: 2, name: "鈴木 一郎")])
        #expect(sink.kinds == ["speakers"])
        let text = try String(contentsOfFile: try #require(named.transcriptPath), encoding: .utf8)
        #expect(text.contains("相手（鈴木 一郎）: 二人目の話です") && text.contains("相手（話者 1）: 最初の人の話です") && text.contains("本人: 分かりました"))

        // もう一度戻す（アプリを終了したあとの想像）：名前は、確定済み。同じ話者は、変えられない。
        let again = try #require(RestoredSession(snapshot: try store.readSnapshot(sessionId: live.sessionId).get(), sink: RecordingSink(), store: SessionStore(root: root), currentModelRevision: "rev1", library: nil))
        #expect(await again.speakerNames() == [2: "鈴木 一郎"])
        guard case .failure(.alreadyNamed(2)) = await again.nameSpeakers([2: "別の人"]) else { Issue.record("確定済みを変えられる"); return }
        #expect(store.pastMeetings().first?.named == 1 && store.pastMeetings().first?.speakers == 2)
    }

    @Test("分離モデルの版が違えば、声の特徴は使わない（「この声を覚える」ができない）。声紋があれば、名前の無い話者の候補だけを作る（名前は付けない）")
    func revisionAndCandidates() async throws {
        let root = tempURL("snap-revision")
        defer { try? FileManager.default.removeItem(at: root) }
        let (live, _) = try await endedMeeting(root)
        let snapshot = try SavedAudioStore(root: root).readSnapshot(sessionId: live.sessionId).get()
        let other = try #require(RestoredSession(snapshot: snapshot, sink: RecordingSink(), store: SessionStore(root: root), currentModelRevision: "rev2", library: nil))
        #expect(await other.voiceEmbedding(of: 1) == nil)

        var library = VoiceprintLibrary(modelRevision: "rev1")
        try library.add(name: "佐藤 花子", vector: [1, 0, 0], now: Date())
        let same = try #require(RestoredSession(snapshot: snapshot, sink: RecordingSink(), store: SessionStore(root: root), currentModelRevision: "rev1", library: library))
        #expect(await same.speakerCandidates()[1]?.first?.name == "佐藤 花子")
        #expect(await same.speakerNames().isEmpty, "名前は、自動では付けない")
    }

    @Test("過去の会議でも、分け直せる：名前が外れ、写しが更新される（版は、いまの版）。保存した音声が無ければ、できない")
    func reseparatingARestoredMeeting() async throws {
        let root = tempURL("snap-reseparate")
        defer { try? FileManager.default.removeItem(at: root) }
        let (live, _) = try await endedMeeting(root)
        let store = SavedAudioStore(root: root)
        let restored = try #require(RestoredSession(snapshot: try store.readSnapshot(sessionId: live.sessionId).get(), sink: RecordingSink(), store: SessionStore(root: root), currentModelRevision: "rev1", library: nil))
        _ = try await restored.nameSpeakers([1: "佐藤"]).get()
        let result = try await restored.reseparate(audio: store, separator: Stub(segments: [VoiceSegment(speaker: "q", start: 0, end: 12)], embeddings: ["q": [0, 0, 1]]), library: nil, modelRevision: "rev2").get()
        #expect(result.reseparated == true && result.speakers.isEmpty)
        let snapshot = try store.readSnapshot(sessionId: live.sessionId).get()
        #expect(snapshot.modelRevision == "rev2" && snapshot.voiceNames.isEmpty && snapshot.embeddings == ["1": [0, 0, 1]])

        store.deleteAll()
        guard case .failure(.missing) = store.readSnapshot(sessionId: live.sessionId) else { Issue.record("音声を消したのに、写しが残る"); return }
        guard case .failure(.audio(.missing)) = await restored.reseparate(audio: store, separator: Stub(segments: []), library: nil, modelRevision: nil) else { Issue.record("音声が無いのに、分け直せる"); return }
        #expect(!FileManager.default.fileExists(atPath: store.snapshotURL(sessionId: live.sessionId).path), "「保存した音声をすべて削除」は、写しも消す")
    }
}

@Suite("あとからの名付け：コントローラー（SPEC §3.16）")
@MainActor
struct LaterNamingControllerTests {
    private func controller(_ root: URL) -> (MeetingController, UserDefaults, String) {
        let name = "ma-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let controller = MeetingController(environment: ["MEETING_ANALYZER_DATA_DIR": root.path, "MEETING_ANALYZER_SOCKET": "/tmp/ma-\(UUID().uuidString.prefix(8)).sock"], defaults: defaults)
        return (controller, defaults, name)
    }

    @Test("再起動のあとの想像：新しいコントローラーが、音声を保存した過去の会議を選べて、開いて、名前を確定できる。確定は、選びの「確定 N」に出る。知らない会議・音声が消えた会議は、理由つきで断る。メニューの条件は、待機中だけ")
    func openingAPastMeeting() async throws {
        let root = tempURL("later-controller")
        defer { try? FileManager.default.removeItem(at: root) }
        let (live, _) = try await endedMeeting(root)

        let (controller, defaults, suite) = controller(root)
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(controller.namingSession == nil && !controller.canOpenNaming && controller.namingChoices.isEmpty)
        controller.updatePastMeetings(SavedAudioStore(root: root).pastMeetings())
        #expect(controller.canOpenNaming && controller.namingChoices.map(\.id) == [live.sessionId])
        #expect(controller.namingChoices.first?.speakers == 2 && controller.namingChoices.first?.named == 0 && controller.namingChoices.first?.isPrevious == false)

        #expect(await controller.openNaming(live.sessionId) == nil)
        #expect(controller.namingSpeakers.map(\.id) == [1, 2] && controller.namingMeeting?.title == "週次の定例" && controller.namingAudioAvailable)
        #expect(await controller.confirmSpeakerName(2, name: "鈴木 一郎").failure == nil)
        #expect(controller.namedSpeakers == [2: "鈴木 一郎"])

        // 確定は、記録（transcript.md）に書かれている。
        let text = try String(contentsOf: SessionStore(root: root).transcriptURL(sessionId: live.sessionId), encoding: .utf8)
        #expect(text.contains("相手（鈴木 一郎）: 二人目の話です"))

        let unknown = await controller.openNaming(UUID())
        #expect(unknown?.contains("保存されていません") == true, "知らない会議は、理由つきで断る: \(String(describing: unknown))")
        SavedAudioStore(root: root).deleteAll()
        #expect(await controller.openNaming(UUID()) != nil)
    }

    @Test("直前の会議と過去の会議を、行き来できる：直前の会議は、同じ状態のまま（名前を確定したまま）。同じ会議を重複して選びに出さない。次の会議の開始（clearNaming）で、直前の会議は手放すが、過去の会議の一覧は残る")
    func switchingBetweenMeetings() async throws {
        let root = tempURL("later-switch")
        defer { try? FileManager.default.removeItem(at: root) }
        let (old, _) = try await endedMeeting(root)
        let (recent, _) = try await endedMeeting(root)
        let (controller, defaults, suite) = controller(root)
        defer { defaults.removePersistentDomain(forName: suite) }

        controller.previousSession = recent
        controller.previousMeeting = NamingMeeting(sessionId: recent.sessionId, title: recent.title, startedAt: recent.startedAt)
        _ = await controller.adoptNaming(recent, meeting: controller.previousMeeting!)
        controller.updatePastMeetings(SavedAudioStore(root: root).pastMeetings())
        #expect(Set(controller.namingChoices.map(\.id)) == [old.sessionId, recent.sessionId], "同じ会議は 1 つ")
        #expect(controller.namingChoices.filter(\.isPrevious).map(\.id) == [recent.sessionId])

        #expect(await controller.confirmSpeakerName(1, name: "佐藤").failure == nil)
        #expect(await controller.openNaming(old.sessionId) == nil)
        #expect(controller.namingMeeting?.sessionId == old.sessionId && controller.namedSpeakers.isEmpty, "過去の会議の状態に替わる")
        #expect(await controller.openNaming(recent.sessionId) == nil)
        #expect(controller.namedSpeakers == [1: "佐藤"], "直前の会議は、確定したまま")

        controller.clearNaming()
        #expect(controller.namingSession == nil && controller.previousSession == nil && controller.namingChoices.map(\.id).count == 2, "一覧（音声を保存した会議）は残る")
    }
}
