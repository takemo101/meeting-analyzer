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

private struct StubSeparator: VoiceSeparating {
    let segments: [VoiceSegment]
    func separate(_ samples: [Float]) async throws -> [VoiceSegment] { segments }
}

@Suite("話者の名付け：名前の規則・話者ごとの要約（SPEC §3.15）")
struct SpeakerNamingRuleTests {
    @Test("名前は、前後の空白を除いて、1〜40 文字。空・長すぎる・改行や制御文字を含むものは断る")
    func normalizesNames() {
        #expect(SpeakerNameRule.normalize("  佐藤 花子 \n") == "佐藤 花子")
        #expect(SpeakerNameRule.normalize(String(repeating: "あ", count: 40)) != nil)
        #expect(SpeakerNameRule.normalize(String(repeating: "あ", count: 41)) == nil)
        #expect(SpeakerNameRule.normalize("   ") == nil && SpeakerNameRule.normalize("") == nil)
        #expect(SpeakerNameRule.normalize("佐藤\n花子") == nil && SpeakerNameRule.normalize("佐藤\u{7}") == nil)
    }

    @Test("話者ごとの要約：確定した「相手」の発話だけ。話した時間・発言数・長い発言から 3 件（時刻の順。60 文字まで）")
    func summarizesPerSpeaker() {
        var transcript = Transcript()
        func add(_ id: Int, _ text: String, _ start: Double, _ end: Double, voice: Int?, final: Bool = true, speaker: Speaker = .others) {
            transcript.record(Utterance(id: id, speaker: speaker, text: text, isFinal: final, startedAt: start, endedAt: end, voice: voice))
        }
        add(1, "短い", 0, 1, voice: 1)
        add(2, "二番目に長い発言です", 2, 6, voice: 1)
        add(3, String(repeating: "長", count: 80), 7, 12, voice: 1)
        add(4, "三番目の発言の長さです", 13, 15, voice: 1)
        add(5, "もう一人の話者です", 20, 24, voice: 2)
        add(6, "まだ途中です", 30, 31, voice: 2, final: false)
        add(7, "本人の発言", 40, 44, voice: nil, speaker: .you)
        add(8, "声が付かなかった", 50, 52, voice: nil)
        let summaries = transcript.speakerSummaries()
        #expect(summaries.map(\.id) == [1, 2], "話者 N の順。暫定・本人・ID なしは数えない")
        let first = summaries[0]
        #expect(first.utteranceCount == 4 && first.seconds == 1 + 4 + 5 + 2)
        #expect(first.excerpts == ["二番目に長い発言です", String(repeating: "長", count: 60) + "…", "三番目の発言の長さです"], "長い順に 3 件を選び、時刻の順に並べる。60 文字を超える分は切る")
        #expect(summaries[1].utteranceCount == 1 && summaries[1].seconds == 4)
    }

    @Test("記録の行：確定した名前は「相手（名前）」。名前が無い話者は「相手（話者 N）」のまま。名前は、推定の名前より優先する")
    func labelsUseConfirmedNames() {
        let guessed = Utterance(id: 1, speaker: .others, text: "はい", isFinal: true, startedAt: 0, actor: ActorLabel(name: "推定の人", guessed: true), voice: 2)
        #expect(guessed.speakerLabel(confirmedName: "佐藤 花子") == "相手（佐藤 花子）")
        #expect(guessed.speakerLabel(confirmedName: nil) == "相手（話者 2・推定: 推定の人）")
    }
}

@Suite("話者の名付け：記録の書き直しと speakers の出来事")
struct SpeakerNamingPipelineTests {
    private func makePipeline(_ sink: RecordingSink, _ store: SessionStore) -> SessionPipeline {
        let pipeline = SessionPipeline(title: "会議", sink: sink, store: store)
        pipeline.begin(sources: [.others])
        pipeline.ingest(TranscriptionUpdate(text: "最初の人の話です", isFinal: true, start: 0, end: 4), speaker: .others)
        pipeline.ingest(TranscriptionUpdate(text: "二人目の話です", isFinal: true, start: 5, end: 9), speaker: .others)
        pipeline.applyVoices([VoiceSegment(speaker: "x", start: 0, end: 4.5), VoiceSegment(speaker: "y", start: 4.5, end: 12)])
        return pipeline
    }

    @Test("確定すると、記録が名前つきに書き直され（同じ ID の発話すべて）、ended のあとに speakers が出る。ほかの話者は、そのまま")
    func confirmRewritesTheTranscript() throws {
        let sink = RecordingSink(), store = SessionStore(root: tempURL("naming"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let pipeline = makePipeline(sink, store)
        let end = pipeline.finish(reason: .user, endedAt: Date(), at: 12)
        let path = try #require(end.transcriptPath)

        let named = try pipeline.nameSpeakers([1: "  佐藤 花子 "]).get()
        #expect(named.speakers == [SpeakerName(speaker: 1, name: "佐藤 花子")] && named.transcriptPath == path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("相手（佐藤 花子）: 最初の人の話です") && text.contains("相手（話者 2）: 二人目の話です"))
        #expect(text.contains("利用者が確定した名前"))
        #expect(sink.kinds.suffix(2) == ["ended", "speakers"], "確定の出来事は、終了の出来事のあとに出る")
        #expect(sink.events.last == .speakers(named))
    }

    @Test("確定を断る場合：会議が終わる前・空・知らない話者・名前が不正・確定済み。断ったときは、記録も出来事も変わらない")
    func refusalsLeaveNothingBehind() throws {
        let sink = RecordingSink(), store = SessionStore(root: tempURL("naming"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let pipeline = makePipeline(sink, store)
        #expect(pipeline.nameSpeakers([1: "佐藤"]) == .failure(.notFinished))
        let end = pipeline.finish(reason: .user, endedAt: Date(), at: 12)
        let path = try #require(end.transcriptPath)
        let before = try String(contentsOfFile: path, encoding: .utf8)

        #expect(pipeline.nameSpeakers([:]) == .failure(.empty))
        #expect(pipeline.nameSpeakers([9: "佐藤"]) == .failure(.unknownSpeaker(9)))
        #expect(pipeline.nameSpeakers([1: "  "]) == .failure(.invalidName))
        #expect(pipeline.nameSpeakers([1: "佐藤", 2: "改\n行"]) == .failure(.invalidName), "1 件でも不正なら、全体を断る（一部だけ確定しない）")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == before)
        #expect(sink.kinds.last == "ended")

        _ = try pipeline.nameSpeakers([1: "佐藤"]).get()
        #expect(pipeline.nameSpeakers([1: "別の人"]) == .failure(.alreadyNamed(1)), "確定した名前は、変えられない")
        #expect(sink.kinds.filter { $0 == "speakers" }.count == 1)
    }

    @Test("記録を書き直せなければ、確定しない：名前は残らず、出来事も出ず、あとで書けるようになれば、確定できる")
    func writeFailureDoesNotConfirm() throws {
        let sink = RecordingSink(), store = SessionStore(root: tempURL("naming"))
        defer {
            if let end = sink.ends.last, let path = end.transcriptPath { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: (path as NSString).deletingLastPathComponent) }
            try? FileManager.default.removeItem(at: store.root)
        }
        let pipeline = makePipeline(sink, store)
        let end = pipeline.finish(reason: .user, endedAt: Date(), at: 12)
        let path = try #require(end.transcriptPath)
        let directory = (path as NSString).deletingLastPathComponent
        let before = try String(contentsOfFile: path, encoding: .utf8)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)   // 書けなくする
        let outcome = pipeline.nameSpeakers([1: "佐藤"])
        #expect(outcome == .failure(.writeFailed))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == before)
        #expect(sink.kinds.last == "ended")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        #expect((try? pipeline.nameSpeakers([1: "佐藤"]).get()) != nil, "書けるようになったら、同じ話者を確定できる（失敗で、確定済みにならない）")
    }

    @Test("speakers の出来事は、JSON で、kind・sessionId・transcriptPath・speakers を並べる。記録を書かない会議では、transcriptPath を省く")
    func eventEncoding() throws {
        let event = TranscriptEvent.speakers(SpeakersNamed(sessionId: "abc", transcriptPath: "/x/transcript.md", speakers: [SpeakerName(speaker: 2, name: "佐藤 花子")]))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        #expect(json["kind"] as? String == "speakers" && json["sessionId"] as? String == "abc" && json["transcriptPath"] as? String == "/x/transcript.md")
        let list = try #require(json["speakers"] as? [[String: Any]])
        #expect(list.first?["speaker"] as? Int == 2 && list.first?["name"] as? String == "佐藤 花子")
        #expect(try JSONDecoder().decode(TranscriptEvent.self, from: JSONEncoder().encode(event)) == event)
        let bare = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(TranscriptEvent.speakers(SpeakersNamed(sessionId: "abc", transcriptPath: nil, speakers: [])))) as? [String: Any])
        #expect(bare["transcriptPath"] == nil)
    }
}

@Suite("話者の名付け：会議（LiveSession）とコントローラー")
@MainActor
struct SpeakerNamingControllerTests {
    private func endedSession(_ root: URL) async throws -> (LiveSession, RecordingSink) {
        let fake = FakeInputs(), sink = RecordingSink(), clock = TestClock()
        let recorder = VoiceAudioRecorder()
        let inputs = LiveInputs { speaker in
            if speaker == .others { recorder.begin(); recorder.append(tone(12)) }
            return try await fake.inputs.open(speaker)
        }
        let separator = StubSeparator(segments: [VoiceSegment(speaker: "a", start: 0, end: 5.5), VoiceSegment(speaker: "b", start: 5.5, end: 12)])
        let session = LiveSession(
            title: "テスト会議", speakers: [.others], inputs: inputs, sink: sink, store: SessionStore(root: root),
            options: LiveSessionOptions(timing: LiveSessionTiming(clock: { clock.now }, tickInterval: .seconds(60)), voice: LiveSessionVoice(recorder: recorder, separator: separator)),
            notify: { _ in }
        )
        try await session.start()
        fake.emit(.others, "最初の人の話です", final: true, 1, 5)
        fake.emit(.others, "二人目の話です", final: true, 6, 10)
        clock.advance(65)
        _ = try await session.end(reason: .user)
        return (session, sink)
    }

    @Test("会議が終わったあとに、話者の要約が出て、名前を確定でき、speakers が出る。終わる前は断る")
    func liveSessionNaming() async throws {
        let root = tempURL("naming-live")
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, sink) = try await endedSession(root)
        #expect(await session.speakerSummaries().map(\.id) == [1, 2])
        let named = try await session.nameSpeakers([2: "鈴木 一郎"]).get()
        #expect(named.speakers == [SpeakerName(speaker: 2, name: "鈴木 一郎")])
        #expect(sink.kinds.suffix(2) == ["ended", "speakers"])
        let text = try String(contentsOfFile: try #require(named.transcriptPath), encoding: .utf8)
        #expect(text.contains("相手（話者 1）: 最初の人の話です") && text.contains("相手（鈴木 一郎）: 二人目の話です"))
    }

    @Test("コントローラー：名前を付けていない話者がいる間は、名付けを出す。全員確定したら出さない。次の会議の開始（clearNaming）で手放す")
    func controllerFlow() async throws {
        let root = tempURL("naming-controller")
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, _) = try await endedSession(root)
        let name = "ma-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = MeetingController(environment: ["MEETING_ANALYZER_DATA_DIR": root.path, "MEETING_ANALYZER_SOCKET": "/tmp/ma-\(UUID().uuidString.prefix(8)).sock"], defaults: defaults)
        #expect(!controller.canNameSpeakers)
        controller.namingSession = session
        controller.namingSpeakers = await session.speakerSummaries()
        #expect(controller.canNameSpeakers)

        #expect(await controller.confirmSpeakerName(1, name: "") != nil, "空の名前は、理由つきで断る。確定済みにならない")
        #expect(!controller.namedSpeakers.keys.contains(1))
        #expect(await controller.confirmSpeakerName(1, name: "佐藤") == nil)
        #expect(controller.canNameSpeakers, "話者 2 が、まだ")
        #expect(await controller.confirmSpeakerName(2, name: "鈴木") == nil)
        #expect(!controller.canNameSpeakers && controller.namedSpeakers == [1: "佐藤", 2: "鈴木"])

        controller.clearNaming()
        #expect(controller.namingSession == nil && controller.namingSpeakers.isEmpty)
        #expect(await controller.confirmSpeakerName(1, name: "誰か") != nil, "次の会議を始めたあとは、名付けられない")
    }
}

@Suite("話者の名付け：窓口を通って、受け手へ届く")
struct SpeakerNamingHubTests {
    @Test("名付けの確定は、窓口で、終了の出来事のあとに届く（受け手が先に接続していても、あとから接続しても、同じ内容）")
    func speakersReachReceivers() async throws {
        let directory = shortSocketDirectory()
        let server = HubServer(socketPath: directory + "/hub.sock")
        try server.start()
        let store = SessionStore(root: tempURL("naming-hub"))
        defer { server.stop(); try? FileManager.default.removeItem(atPath: directory); try? FileManager.default.removeItem(at: store.root) }

        let early = Inbox(HubClient(socketPath: server.socketPath, retryInterval: 0.05))
        defer { early.close() }
        #expect(await waitUntil { early.messages.contains(.sync) })

        let pipeline = SessionPipeline(title: "会議", sink: server, store: store)
        pipeline.begin(sources: [.others])
        pipeline.ingest(TranscriptionUpdate(text: "最初の人の話です", isFinal: true, start: 0, end: 4), speaker: .others)
        pipeline.applyVoices([VoiceSegment(speaker: "x", start: 0, end: 5)])
        pipeline.finish(reason: .user, endedAt: Date(), at: 5)
        let named = try pipeline.nameSpeakers([1: "佐藤 花子"]).get()
        #expect(await waitUntil { early.envelopes.map(\.event.kind).last == "speakers" })
        #expect(early.envelopes.map(\.event.kind).suffix(2) == ["ended", "speakers"])
        #expect(early.envelopes.last?.event == .speakers(named))

        let late = Inbox(HubClient(socketPath: server.socketPath, retryInterval: 0.05))
        defer { late.close() }
        #expect(await waitUntil { late.messages.contains(.sync) })
        #expect(late.envelopes.last?.event == .speakers(named), "あとから接続した受け手にも、名前つきの確定が届く")
    }
}
