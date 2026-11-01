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

private func permissions(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Suite("相手の音声の保存：書き方・権限・削除（SPEC §3.16）")
struct SavedAudioStoreTests {
    private func samples(_ count: Int) -> [Float] { (0..<count).map { Float(sin(Double($0) * 0.01)) * 0.5 } }

    @Test("保存した WAV は、16 kHz・モノラル・16 bit で、読み戻すと同じ音。権限は 0600・ディレクトリは 0700。時刻の対応も一緒。書きかけを残さない")
    func writesAReadableFile() throws {
        let root = tempURL("saved-audio")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), store = SavedAudioStore(root: root)
        let input = samples(16_000 * 3 + 7)
        let timeline = AudioTimeline(pieces: [.init(origin: 2, duration: 2), .init(origin: 30, duration: Double(input.count) / 16_000 - 2)])
        guard case .success = store.save(samples: input, timeline: timeline, sessionId: id) else { Issue.record("save failed"); return }

        let audio = store.audioURL(sessionId: id)
        #expect(permissions(audio) == 0o600 && permissions(store.timelineURL(sessionId: id)) == 0o600 && permissions(store.directory(sessionId: id)) == 0o700)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.directory(sessionId: id).path).sorted()
        #expect(names == ["others.json", "others.wav"], "書きかけ（.part）を残さない: \(names)")

        let file = try AVAudioFile(forReading: audio)
        #expect(file.fileFormat.sampleRate == 16_000 && file.fileFormat.channelCount == 1 && file.length == Int64(input.count))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let back = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let worst = zip(input, back).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1.0 / 16_384, "16 bit に丸めるだけの違い: \(worst)")

        let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: store.timelineURL(sessionId: id))) as? [String: Any]
        let pieces = stored?["pieces"] as? [[String: Double]]
        #expect(stored?["sampleRate"] as? Int == 16_000 && pieces?.map { $0["origin"] } == [2, 30])
    }

    @Test("書けないとき（置き場所に書けない）は、失敗を返し、ファイルを残さない")
    func failureLeavesNothing() throws {
        let root = tempURL("saved-audio-blocked")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // `sessions` が、ディレクトリでなくファイル → 作れない。
        FileManager.default.createFile(atPath: root.appendingPathComponent("sessions").path, contents: Data())
        let store = SavedAudioStore(root: root)
        guard case .failure = store.save(samples: samples(1_000), timeline: AudioTimeline(pieces: [.init(origin: 0, duration: 1)]), sessionId: UUID()) else { Issue.record("失敗を返さない"); return }
        #expect(store.summary() == SavedAudioSummary())
    }

    @Test("件数と大きさを数える。「すべて削除」は、音声と時刻の対応だけを消し、記録（transcript.md）は残し、フォルダの更新時刻（保持期間の起点）を動かさない")
    func summaryAndDeleteAll() throws {
        let root = tempURL("saved-audio-all")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SavedAudioStore(root: root), sessions = SessionStore(root: root)
        let first = UUID(), second = UUID(), third = UUID()
        for id in [first, second] {
            #expect(sessions.writeTranscript("# 記録", sessionId: id).isSuccess)
            guard case .success = store.save(samples: samples(1_600), timeline: AudioTimeline(pieces: [.init(origin: 0, duration: 0.1)]), sessionId: id) else { Issue.record("save failed"); return }
        }
        #expect(sessions.writeTranscript("# 音声なしの記録", sessionId: third).isSuccess)
        let summary = store.summary()
        #expect(summary.count == 2 && summary.bytes == 2 * (44 + 3_200))

        let old = Date(timeIntervalSinceNow: -5 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: store.directory(sessionId: first).path)
        #expect(store.deleteAll() == 2)
        #expect(store.summary() == SavedAudioSummary())
        for id in [first, second, third] { #expect(FileManager.default.fileExists(atPath: sessions.transcriptURL(sessionId: id).path), "記録は残る") }
        #expect(!FileManager.default.fileExists(atPath: store.timelineURL(sessionId: first).path))
        let modified = try #require((try FileManager.default.attributesOfItem(atPath: store.directory(sessionId: first).path))[.modificationDate] as? Date)
        #expect(abs(modified.timeIntervalSince(old)) < 1, "削除で、保持期間の起点を、現在へ動かさない")
    }

    @Test("記録と同じ寿命：期限を過ぎた会議のフォルダごと、音声も消える。期限内の会議の音声は残る")
    func expiresWithTheRecord() throws {
        let root = tempURL("saved-audio-expire")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SavedAudioStore(root: root), sessions = SessionStore(root: root)
        let expired = UUID(), fresh = UUID()
        for id in [expired, fresh] {
            #expect(sessions.writeTranscript("# 記録", sessionId: id).isSuccess)
            guard case .success = store.save(samples: samples(1_600), timeline: AudioTimeline(pieces: [.init(origin: 0, duration: 0.1)]), sessionId: id) else { Issue.record("save failed"); return }
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -8 * 86_400)], ofItemAtPath: store.directory(sessionId: expired).path)
        #expect(RecordRetention(root: root).deleteExpired(olderThanDays: 7) == 1)
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(sessionId: expired).path))
        #expect(FileManager.default.fileExists(atPath: store.audioURL(sessionId: fresh).path))
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}

private struct FakeSeparator: VoiceSeparating {
    let result: Result<[VoiceSegment], VoiceSeparationError>
    func separate(_ samples: [Float]) async throws -> VoiceSeparation { VoiceSeparation(segments: try result.get()) }
}

@Suite("相手の音声の保存：会議の終了の手順（LiveSession。SPEC §3.16）")
struct SavedAudioLiveSessionTests {
    private struct Rig {
        let fake = FakeInputs(), sink = RecordingSink(), clock = TestClock(), notices = Collected<LiveSessionNotice>()
        let store = SessionStore(root: tempURL("saved-live"))
        let recorder = VoiceAudioRecorder()

        func session(_ separator: FakeSeparator, audioStore: SavedAudioStore?) -> LiveSession {
            let clock = self.clock, notices = self.notices, recorder = self.recorder, fake = self.fake
            let inputs = LiveInputs { speaker in
                if speaker == .others { recorder.begin(); recorder.setOrigin(0); recorder.append(tone(12)) }
                return try await fake.inputs.open(speaker)
            }
            return LiveSession(
                title: "テスト会議", speakers: [.others], inputs: inputs, sink: sink, store: store,
                options: LiveSessionOptions(timing: LiveSessionTiming(clock: { clock.now }, tickInterval: .seconds(60)), voice: LiveSessionVoice(recorder: recorder, separator: separator, audioStore: audioStore)),
                notify: { notices.add($0) }
            )
        }
    }

    private let works = FakeSeparator(result: .success([VoiceSegment(speaker: "a", start: 0, end: 12)]))

    @Test("保存を選んだとき：終了で、相手の音声が、記録と同じフォルダに保存され、メモリの音声は捨てる。`ended` に、音声のパスは出ない")
    func savesAtTheEnd() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.store.root) }
        let audioStore = SavedAudioStore(root: rig.store.root)
        let session = rig.session(works, audioStore: audioStore)
        try await session.start()
        rig.fake.emit(.others, "話です", final: true, 1, 5)
        rig.clock.advance(65)
        let outcome = try await session.end(reason: .user)

        let id = session.sessionId
        let audio = audioStore.audioURL(sessionId: id)
        #expect(FileManager.default.fileExists(atPath: audio.path) && permissions(audio) == 0o600)
        #expect(audio.deletingLastPathComponent() == URL(fileURLWithPath: try #require(outcome.transcriptPath)).deletingLastPathComponent(), "記録と同じフォルダ")
        #expect(rig.recorder.seconds == 0)
        let ended = try #require(rig.sink.events.last)
        let json = String(decoding: try JSONEncoder().encode(ended), as: UTF8.self)
        #expect(!json.contains("others.wav") && !json.contains(".wav"), "音声のパスは、出来事に出ない")
    }

    @Test("保存を選ばないとき：何も保存しない（既定）")
    func savesNothingByDefault() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.store.root) }
        let session = rig.session(works, audioStore: nil)
        try await session.start()
        rig.clock.advance(65)
        let outcome = try await session.end(reason: .user)
        let id = session.sessionId
        #expect(!FileManager.default.fileExists(atPath: SavedAudioStore(root: rig.store.root).audioURL(sessionId: id).path))
    }

    @Test("分離に失敗しても、音声は保存する（あとで、分け直せる）")
    func savesEvenWhenSeparationFails() async throws {
        let rig = Rig()
        defer { try? FileManager.default.removeItem(at: rig.store.root) }
        let audioStore = SavedAudioStore(root: rig.store.root)
        let session = rig.session(FakeSeparator(result: .failure(.failed("GPU"))), audioStore: audioStore)
        try await session.start()
        rig.fake.emit(.others, "話です", final: true, 1, 5)
        rig.clock.advance(65)
        _ = try await session.end(reason: .user)
        #expect(FileManager.default.fileExists(atPath: audioStore.audioURL(sessionId: session.sessionId).path))
    }

    @Test("保存に失敗しても、会議は終わる：記録は書き、見出しに理由が残り、1 回だけ知らせる。ファイルは残らない")
    func saveFailureDoesNotBreakTheEnd() async throws {
        let rig = Rig()
        let blocked = tempURL("saved-live-blocked")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: blocked.appendingPathComponent("sessions").path, contents: Data())
        defer { try? FileManager.default.removeItem(at: rig.store.root); try? FileManager.default.removeItem(at: blocked) }
        let session = rig.session(works, audioStore: SavedAudioStore(root: blocked))
        try await session.start()
        rig.fake.emit(.others, "話です", final: true, 1, 5)
        rig.clock.advance(65)
        let outcome = try await session.end(reason: .user)
        #expect(outcome.utterances == 1)
        let text = try String(contentsOfFile: try #require(outcome.transcriptPath), encoding: .utf8)
        #expect(text.contains("- 相手の音声: 保存できませんでした（") && text.contains("相手（話者 1）: 話です"))
        #expect(rig.notices.values.filter { if case .audioNotSaved = $0 { return true } else { return false } }.count == 1)
        #expect(SavedAudioStore(root: blocked).summary() == SavedAudioSummary())
    }
}

@Suite("相手の音声の保存：設定（SPEC §3.16）")
@MainActor
struct SavedAudioSettingsTests {
    private let model = VoiceModelCatalog.all[0]

    private func defaults() -> UserDefaults {
        let name = "ma-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func controller(_ root: URL, _ defaults: UserDefaults) -> MeetingController {
        MeetingController(environment: ["MEETING_ANALYZER_DATA_DIR": root.path, "MEETING_ANALYZER_SOCKET": "/tmp/ma-\(UUID().uuidString.prefix(8)).sock"], defaults: defaults)
    }

    private func install(_ model: VoiceModel, in root: URL) throws {
        let store = ModelStore(root: root)
        for artifact in model.artifacts {
            try store.prepareParent(of: artifact)
            FileManager.default.createFile(atPath: store.fileURL(artifact).path, contents: nil)
            let handle = try FileHandle(forWritingTo: store.fileURL(artifact))
            try handle.truncate(atOffset: UInt64(artifact.bytes))
            try handle.close()
            store.markVerified(artifact)
        }
    }

    @Test("既定はオフ。声の分離がオフなら、オンにできない。オンにできて、覚える。分離をオフにすると、保存もオフに戻る。保存した値が壊れていても（分離がオフなら）、起動でオフへ戻す")
    func followsSeparation() throws {
        let root = tempURL("saved-settings"), defaults = defaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = controller(root, defaults)
        #expect(!first.saveOthersAudio)
        first.setSaveOthersAudio(true)
        #expect(!first.saveOthersAudio, "分離がオフのときは、オンにできない")

        try install(model, in: root)
        first.setVoiceSeparation(true)
        first.setSaveOthersAudio(true)
        #expect(first.saveOthersAudio && controller(root, defaults).saveOthersAudio, "再起動しても、同じ")
        first.setVoiceSeparation(false)
        #expect(!first.saveOthersAudio && !controller(root, defaults).saveOthersAudio)

        defaults.set(true, forKey: "capture.saveOthersAudio")
        #expect(!controller(root, defaults).saveOthersAudio, "分離がオフなら、起動のときにオフへ戻す")
    }

    @Test("「すべて削除」：音声だけが消え、件数が 0 になる。記録は残る")
    func deleteAll() async throws {
        let root = tempURL("saved-settings-delete"), defaults = defaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        _ = SessionStore(root: root).writeTranscript("# 記録", sessionId: id)
        _ = SavedAudioStore(root: root).save(samples: [0.1, 0.2, 0.3], timeline: AudioTimeline(pieces: [.init(origin: 0, duration: 0.001)]), sessionId: id)
        let controller = controller(root, defaults)
        #expect(controller.savedAudio.count == 1, "起動で数える")
        controller.deleteSavedAudio()
        for _ in 0..<100 where controller.savedAudio.count != 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(controller.savedAudio.count == 0)
        #expect(FileManager.default.fileExists(atPath: SessionStore(root: root).transcriptURL(sessionId: id).path))
    }
}

@Suite("相手の音声の保存：CLI（replay --save-audio）")
struct SavedAudioOptionTests {
    @Test("--save-audio は、値を取らない。--separate と一緒でなければ、使えない。無指定は、保存しない")
    func parses() {
        guard case .success(.replay(let plain)) = CommandParser.parse(["replay", "a.wav", "--separate"]) else { Issue.record("parse failed"); return }
        #expect(!plain.saveAudio)
        guard case .success(.replay(let saving)) = CommandParser.parse(["replay", "a.wav", "--save-audio", "--separate"]) else { Issue.record("parse failed"); return }
        #expect(saving.saveAudio && saving.separate)
        guard case .failure(.usage) = CommandParser.parse(["replay", "a.wav", "--save-audio"]) else { Issue.record("--separate なしを断らない"); return }
    }
}
