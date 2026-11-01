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
    var embeddings: [String: [Float]] = [:]
    func separate(_ samples: [Float]) async throws -> VoiceSeparation { VoiceSeparation(segments: segments, embeddings: embeddings) }
}

/// 本文で、決まった確率を返す偽の判断モデル（「最初」を含めば、佐藤 0.9。そうでなければ、田中 0.8）。
private struct TextJudge: SpeakerJudge {
    func judge(utterance: String, candidates: [Actor]) async throws -> SpeakerJudgement {
        let sato = utterance.contains("最初")
        return SpeakerJudgement(probabilities: candidates.map { candidate in
            if candidates.count == 1 { return 1 }
            switch candidate.name {
            case "佐藤 花子": return sato ? 0.9 : 0.2
            case "田中 美咲": return sato ? 0.1 : 0.8
            default: return 0
            }
        }, filler: 0)
    }
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
    private func endedSession(_ root: URL, embeddings: [String: [Float]] = [:], library: VoiceprintLibrary? = nil) async throws -> (LiveSession, RecordingSink) {
        let fake = FakeInputs(), sink = RecordingSink(), clock = TestClock()
        let recorder = VoiceAudioRecorder()
        let inputs = LiveInputs { speaker in
            if speaker == .others { recorder.begin(); recorder.append(tone(12)) }
            return try await fake.inputs.open(speaker)
        }
        let separator = StubSeparator(segments: [VoiceSegment(speaker: "a", start: 0, end: 5.5), VoiceSegment(speaker: "b", start: 5.5, end: 12)], embeddings: embeddings)
        let session = LiveSession(
            title: "テスト会議", speakers: [.others], inputs: inputs, sink: sink, store: SessionStore(root: root),
            options: LiveSessionOptions(timing: LiveSessionTiming(clock: { clock.now }, tickInterval: .seconds(60)), voice: LiveSessionVoice(recorder: recorder, separator: separator, library: library)),
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

        #expect(await controller.confirmSpeakerName(1, name: "").failure != nil, "空の名前は、理由つきで断る。確定済みにならない")
        #expect(!controller.namedSpeakers.keys.contains(1))
        #expect(await controller.confirmSpeakerName(1, name: "佐藤").failure == nil)
        #expect(controller.canNameSpeakers, "話者 2 が、まだ")
        #expect(await controller.confirmSpeakerName(2, name: "鈴木").failure == nil)
        #expect(!controller.canNameSpeakers && controller.namedSpeakers == [1: "佐藤", 2: "鈴木"])

        controller.clearNaming()
        #expect(controller.namingSession == nil && controller.namingSpeakers.isEmpty)
        #expect(await controller.confirmSpeakerName(1, name: "誰か").failure != nil, "次の会議を始めたあとは、名付けられない")
    }

    // MARK: 声紋（SPEC §3.15）

    private func voiceDefaults() -> UserDefaults {
        let name = "ma-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func voiceController(_ root: URL, _ defaults: UserDefaults) -> MeetingController {
        MeetingController(environment: ["MEETING_ANALYZER_DATA_DIR": root.path, "MEETING_ANALYZER_SOCKET": "/tmp/ma-\(UUID().uuidString.prefix(8)).sock"], defaults: defaults)
    }

    /// 分離のモデルを、取得済みに見せる（大きさだけ合わせた疎なファイルと、検証済みの印）。
    private func installVoiceModel(in root: URL) throws {
        let store = ModelStore(root: root), model = VoiceModelCatalog.all[0]
        for artifact in model.artifacts {
            try store.prepareParent(of: artifact)
            FileManager.default.createFile(atPath: store.fileURL(artifact).path, contents: nil)
            let handle = try FileHandle(forWritingTo: store.fileURL(artifact))
            try handle.truncate(atOffset: UInt64(artifact.bytes))
            try handle.close()
            store.markVerified(artifact)
        }
    }

    @Test("声紋を使うのは、声による話者の分離がオンのときだけ。分離をオフにすると、声紋もオフ。覚えていて、再起動後も同じ。分離がオフなら、起動のときに、オフへ戻る")
    func voiceprintSwitchFollowsSeparation() throws {
        let root = tempURL("vp-switch"), defaults = voiceDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = voiceController(root, defaults)
        first.setVoiceprints(true)
        #expect(!first.voiceprintsEnabled, "分離がオフのあいだは、オンにできない")
        try installVoiceModel(in: root)
        first.setVoiceSeparation(true)
        first.setVoiceprints(true)
        #expect(first.voiceprintsEnabled)
        #expect(voiceController(root, defaults).voiceprintsEnabled, "再起動後も同じ")
        first.setVoiceSeparation(false)
        #expect(!first.voiceprintsEnabled && !voiceController(root, defaults).voiceprintsEnabled, "分離をオフにすると、声紋もオフ")
    }

    @Test("「この声を覚える」：確定した名前に、その話者の声の特徴を結んで保存する。次の会議では、同じ声の話者に、確定の前に、名前が付く。保存した声紋は、一覧・削除ができる")
    func rememberThenRecognizeNextMeeting() async throws {
        let root = tempURL("vp-flow"), defaults = voiceDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        try installVoiceModel(in: root)
        let controller = voiceController(root, defaults)
        controller.setVoiceSeparation(true)
        controller.setVoiceprints(true)

        // 1 回目：声の特徴 a = [1,0]、b = [0,1]。話者 1 に「佐藤」を付けて、覚える。話者 2 は、覚えない。
        let (first, _) = try await endedSession(root, embeddings: ["a": [1, 0], "b": [0, 1]])
        controller.namingSession = first
        controller.namingSpeakers = await first.speakerSummaries()
        #expect(await controller.confirmSpeakerName(1, name: "佐藤", remember: true) == .init())
        #expect(await controller.confirmSpeakerName(2, name: "鈴木", remember: false) == .init())
        #expect(controller.voiceprintRows.map(\.name) == ["佐藤"] && controller.voiceprintRows.first?.vectorCount == 1)
        let stored = try Data(contentsOf: root.appendingPathComponent("voiceprints.json"))
        #expect(!String(decoding: stored, as: UTF8.self).contains("鈴木"), "覚えなかった人は、保存しない")
        #expect((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("voiceprints.json").path)[.posixPermissions] as? Int) == 0o600)

        // 2 回目：同じ声（わずかにずれた特徴）が、話者 1 に当たる。保存した声紋を、会議の開始のときに読んだ写しとして渡す。
        guard case .loaded(let library) = controller.voiceprintStore.load() else { Issue.record("声紋を読めない"); return }
        let (second, sink) = try await endedSession(root, embeddings: ["a": [0.98, 0.1], "b": [0.1, 0.99]], library: library)
        #expect(await second.speakerNames() == [1: "佐藤"], "話者 1 は、確定の前に、名前が付く。話者 2（類似度が低い）は、付かない")
        let text = try String(contentsOfFile: try #require(sink.ends.last?.transcriptPath), encoding: .utf8)
        #expect(text.contains("相手（佐藤）: 最初の人の話です") && text.contains("相手（話者 2）: 二人目の話です"))
        #expect(sink.kinds.last == "ended", "自動の名前は、ended の前に確定する（speakers の出来事は、出ない）")

        controller.deleteVoiceprint("佐藤")
        #expect(controller.voiceprintRows.isEmpty && !FileManager.default.fileExists(atPath: root.appendingPathComponent("voiceprints.json").path), "誰もいなくなったら、ファイルも消える")
    }

    @Test("声の特徴を取れなかった話者・声紋を使わないときは、名前は確定し、覚えない（理由を返す／何も保存しない）")
    func rememberFailureKeepsTheName() async throws {
        let root = tempURL("vp-warn"), defaults = voiceDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        try installVoiceModel(in: root)
        let controller = voiceController(root, defaults)
        controller.setVoiceSeparation(true)
        controller.setVoiceprints(true)
        let (session, _) = try await endedSession(root)   // 声の特徴なし
        controller.namingSession = session
        controller.namingSpeakers = await session.speakerSummaries()
        let outcome = await controller.confirmSpeakerName(1, name: "佐藤", remember: true)
        #expect(outcome.failure == nil && outcome.warning != nil && controller.namedSpeakers[1] == "佐藤")
        #expect(controller.voiceprintRows.isEmpty)

        controller.setVoiceprints(false)
        let off = await controller.confirmSpeakerName(2, name: "鈴木", remember: true)
        #expect(off == .init() && controller.voiceprintRows.isEmpty, "声紋を使わないなら、覚える指定があっても、何も保存しない")
    }

    @Test("壊れた声紋のファイルは、使わず、消さない。設定の「すべて削除」で作り直せる")
    func brokenFileIsKeptUntilDeleted() throws {
        let root = tempURL("vp-broken"), defaults = voiceDefaults()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("voiceprints.json")
        try Data("{壊れている".utf8).write(to: file)
        let controller = voiceController(root, defaults)
        #expect(controller.voiceprintProblem != nil && controller.voiceprintRows.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path), "読めなくても、消さない")
        controller.deleteAllVoiceprints()
        #expect(controller.voiceprintProblem == nil && !FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: 名前のヒント（SPEC §3.13）

    private func installDecisionModel(in root: URL) throws {
        let store = ModelStore(root: root), model = DecisionModelCatalog.all[0]
        for artifact in model.artifacts {
            try store.prepareParent(of: artifact)
            FileManager.default.createFile(atPath: store.fileURL(artifact).path, contents: nil)
            let handle = try FileHandle(forWritingTo: store.fileURL(artifact))
            try handle.truncate(atOffset: UInt64(artifact.bytes))
            try handle.close()
            store.markVerified(artifact)
        }
    }

    /// ACTOR.md を選び、判断モデルを選んだ、名付けの対象の会議つきのコントローラー。
    private func hintSetup(_ root: URL, factory: @escaping @Sendable (DecisionModel, ModelStore, [Actor]) throws -> any SpeakerJudge) async throws -> MeetingController {
        try installDecisionModel(in: root)
        let file = root.appendingPathComponent("ACTOR.md")
        try Data(actorSample.utf8).write(to: file)
        let controller = voiceController(root, voiceDefaults())
        controller.setDecisionModel(DecisionModelCatalog.all[0])
        controller.setActorFile(file.path)
        controller.hintJudgeFactory = factory
        let (session, _) = try await endedSession(root)
        controller.namingSession = session
        controller.namingSpeakers = await session.speakerSummaries()
        return controller
    }

    @Test("名付けの画面を開くと、名前の無い話者ごとに、ヒントを計算する（確定ではない）。1 回の名付けにつき 1 回だけ。確定済みの話者は、計算しない")
    func hintsAreComputedOnceForUnnamedSpeakers() async throws {
        let root = tempURL("hints-controller")
        defer { try? FileManager.default.removeItem(at: root) }
        let loads = Collected<String>()
        let controller = try await hintSetup(root) { _, _, _ in loads.add("load"); return TextJudge() }
        controller.namedSpeakers = [2: "鈴木"]
        #expect(controller.hintState == .notRequested)
        await controller.computeNamingHints()
        #expect(controller.hintState == .ready)
        #expect(controller.namingHints[1]?.first == SpeakerHint(name: "佐藤 花子", probability: 0.9, introduced: false))
        #expect(controller.namingHints[2] == nil, "確定済みの話者は、計算しない")
        #expect(controller.namedSpeakers == [2: "鈴木"] && controller.canNameSpeakers, "ヒントは、名前を確定しない")
        await controller.computeNamingHints()
        #expect(loads.values.count == 1, "開き直しても、モデルを読み直さない")
        controller.clearNaming()
        #expect(controller.namingHints.isEmpty && controller.hintState == .notRequested)
    }

    @Test("判断モデルを選んでいない・ACTOR.md が無いときは、ヒントを計算しない（理由も出さない）")
    func hintsNeedAModelAndActors() async throws {
        let root = tempURL("hints-controller")
        defer { try? FileManager.default.removeItem(at: root) }
        let loads = Collected<String>()
        let controller = try await hintSetup(root) { _, _, _ in loads.add("load"); return TextJudge() }
        controller.setDecisionModel(nil)
        await controller.computeNamingHints()
        #expect(controller.hintState == .notRequested && controller.namingHints.isEmpty && loads.values.isEmpty, "判断モデルを選んでいない")
        controller.setDecisionModel(DecisionModelCatalog.all[0])
        controller.setActorFile(nil)
        await controller.computeNamingHints()
        #expect(controller.hintState == .notRequested && loads.values.isEmpty, "ACTOR.md を選んでいない")
    }

    @Test("モデルを読み込めなければ、理由を出す。名付けは、できる")
    func hintFailureIsReportedAndNamingStillWorks() async throws {
        let root = tempURL("hints-controller")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try await hintSetup(root) { _, _, _ in throw DecisionModelError.noGPU }
        await controller.computeNamingHints()
        guard case .failed(let reason) = controller.hintState else { Issue.record("失敗にならない"); return }
        #expect(reason.contains("GPU") && controller.namingHints.isEmpty)
        #expect(await controller.confirmSpeakerName(1, name: "佐藤").failure == nil, "ヒントが無くても、名付けは、できる")
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

/// 単位ベクトル（x 軸との間の角の余弦が `cosine`）。
private func vec(_ cosine: Double) -> [Float] { [Float(cosine), Float((1 - cosine * cosine).squareRoot())] }

@Suite("声紋：照合の規則（SPEC §3.15）")
struct VoiceprintLibraryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func library(_ people: [(String, [Float])]) throws -> VoiceprintLibrary {
        var library = VoiceprintLibrary(modelRevision: "rev")
        for (name, vector) in people { try library.add(name: name, vector: vector, now: now) }
        return library
    }

    @Test("自動は、類似度 0.8 以上で、次点（別の人）との差が 0.1 以上のときだけ。0.45〜0.8 は候補。0.45 未満は何も返さない")
    func thresholds() throws {
        let library = try library([("佐藤", [1, 0])])
        #expect(library.match(vec(0.81)).automatic?.name == "佐藤")
        let middle = library.match(vec(0.79))
        #expect(middle.automatic == nil && middle.candidates.map(\.name) == ["佐藤"], "0.8 未満は、自動にしない。候補にする")
        #expect(library.match(vec(0.46)).candidates.map(\.name) == ["佐藤"])
        let low = library.match(vec(0.44))
        #expect(low.automatic == nil && low.candidates.isEmpty)
    }

    @Test("2 人が近いときは、自動にしない（差が 0.1 未満）：どちらも候補。差が 0.1 以上なら、高いほうが自動")
    func runnerUpMargin() throws {
        let library = try library([("佐藤", [1, 0]), ("鈴木", vec(0.8))])
        let close = library.match(vec(0.95))   // 佐藤 0.95・鈴木 ≈ 0.947
        #expect(close.automatic == nil && Set(close.candidates.map(\.name)) == ["佐藤", "鈴木"])
        let clear = library.match([1, 0])      // 佐藤 1.0・鈴木 0.8
        #expect(clear.automatic?.name == "佐藤")
    }

    @Test("1 人が複数の声紋を持つときは、最大の類似度を使う。長さの違う・0 ベクトル・有限でない特徴は、比べない")
    func bestVectorAndInvalidInput() throws {
        let library = try library([("佐藤", [1, 0]), ("佐藤", [0, 1])])
        #expect(library.people.count == 1 && library.people[0].vectors.count == 2)
        #expect(library.ranking(of: [0, 1]).first?.similarity ?? 0 > 0.999)
        #expect(library.ranking(of: [1, 0, 0]).first?.similarity == 0, "長さが違えば、0")
        #expect(library.ranking(of: [0, 0]).isEmpty && library.ranking(of: [.nan, 1]).isEmpty && library.ranking(of: []).isEmpty)
    }

    @Test("覚える：1 人 5 つまで（古いものから置き換える）・50 人まで。名前・特徴が不正なら断る")
    func addLimits() throws {
        var library = VoiceprintLibrary(modelRevision: "rev")
        for angle in 1...6 { try library.add(name: "佐藤", vector: [Float(angle), 1], now: now) }
        #expect(library.people[0].vectors.count == 5)
        #expect(library.people[0].vectors.first.map { abs($0[0] - Float(2 / 5.0.squareRoot())) < 0.001 } == true, "最初の 1 つ（[1,1]）が、捨てられた")
        for index in 1..<VoiceprintLibrary.maxPeople { try library.add(name: "人\(index)", vector: [1, 0], now: now) }
        #expect(library.people.count == VoiceprintLibrary.maxPeople)
        #expect(throws: VoiceprintLibrary.AddError.full) { try library.add(name: "あふれた人", vector: [1, 0], now: now) }
        #expect(throws: VoiceprintLibrary.AddError.invalidName) { try library.add(name: "  ", vector: [1, 0], now: now) }
        #expect(throws: VoiceprintLibrary.AddError.invalidVector) { try library.add(name: "佐藤", vector: [0, 0], now: now) }
        try library.add(name: "佐藤", vector: [1, 1], now: now)   // 50 人でも、いる人への追加はできる
    }
}

@Suite("声紋：保管（0600・検査・壊れたファイルを消さない）")
struct VoiceprintStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("保存して読める（往復）。ファイルは 0600・新しく作ったディレクトリは 0700。誰もいなくなれば、ファイルを消す")
    func roundTripAndPermissions() throws {
        let root = tempURL("vp-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceprintStore(root: root)
        #expect(store.load() == .none)
        var library = VoiceprintLibrary(modelRevision: "rev-1")
        try library.add(name: "佐藤 花子", vector: [3, 4], now: now)
        try store.save(library)
        guard case .loaded(let loaded) = store.load() else { Issue.record("読めない"); return }
        #expect(loaded.modelRevision == "rev-1" && loaded.people.map(\.name) == ["佐藤 花子"] && loaded.people[0].lastUsed == now)
        #expect(abs(loaded.people[0].vectors[0][0] - 0.6) < 1e-6 && abs(loaded.people[0].vectors[0][1] - 0.8) < 1e-6, "長さ 1 に正規化して持つ")
        #expect((try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int) == 0o700)
        library.removeAll()
        try store.save(library)
        #expect(store.load() == .none && !FileManager.default.fileExists(atPath: store.file.path))
    }

    @Test("壊れた・知らない書式・不正な中身は、使わず（理由つき）、ファイルを消さない")
    func unusableFilesAreKept() throws {
        let root = tempURL("vp-store-bad")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VoiceprintStore(root: root)
        func check(_ json: String, _ label: String) throws {
            try Data(json.utf8).write(to: store.file)
            guard case .unusable = store.load() else { Issue.record("\(label): 使えないはず"); return }
            #expect(FileManager.default.fileExists(atPath: store.file.path), "\(label): 消さない")
        }
        let person = #"{"name":"佐藤","vectors":[[1,0]],"lastUsed":"2026-11-01T00:00:00Z"}"#
        try check("これは JSON ではない", "壊れている")
        try check(#"{"version":2,"modelRevision":"r","people":[\#(person)]}"#, "知らない版")
        try check(#"{"version":1,"modelRevision":"r","people":[{"name":"","vectors":[[1,0]],"lastUsed":"2026-11-01T00:00:00Z"}]}"#, "空の名前")
        try check(#"{"version":1,"modelRevision":"r","people":[\#(person),\#(person)]}"#, "同じ名前が 2 つ")
        try check(#"{"version":1,"modelRevision":"r","people":[{"name":"佐藤","vectors":[],"lastUsed":"2026-11-01T00:00:00Z"}]}"#, "声が 0 件")
        try check(#"{"version":1,"modelRevision":"r","people":[{"name":"佐藤","vectors":[[0,0]],"lastUsed":"2026-11-01T00:00:00Z"}]}"#, "0 ベクトル")
        try check(#"{"version":1,"modelRevision":"r","people":[{"name":"佐藤","vectors":[[1,0],[1,0],[1,0],[1,0],[1,0],[1,0]],"lastUsed":"2026-11-01T00:00:00Z"}]}"#, "6 件")
    }
}

@Suite("声紋：会議の終了時の照合（パイプライン）")
struct VoiceprintPipelineTests {
    @Test("自動の条件を満たす話者に、名前が付く（記録は「相手（名前）」）。付かなかった話者は、候補（0.45〜0.8）か話者 N のまま。付いた話者は、あとから変えられない")
    func matchesAtTheEnd() throws {
        let sink = RecordingSink(), store = SessionStore(root: tempURL("vp-pipeline"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let pipeline = SessionPipeline(title: "会議", sink: sink, store: store)
        pipeline.begin(sources: [.others])
        pipeline.ingest(TranscriptionUpdate(text: "最初の人の話です", isFinal: true, start: 0, end: 4), speaker: .others)
        pipeline.ingest(TranscriptionUpdate(text: "二人目の話です", isFinal: true, start: 5, end: 9), speaker: .others)
        pipeline.ingest(TranscriptionUpdate(text: "三人目の話です", isFinal: true, start: 10, end: 14), speaker: .others)
        pipeline.applyVoices(
            [VoiceSegment(speaker: "x", start: 0, end: 4.5), VoiceSegment(speaker: "y", start: 4.5, end: 9.5), VoiceSegment(speaker: "z", start: 9.5, end: 15)],
            embeddings: ["x": vec(0.95), "y": vec(0.6), "z": vec(0.2)]
        )
        var library = VoiceprintLibrary(modelRevision: "rev")
        try library.add(name: "佐藤", vector: [1, 0], now: Date())
        #expect(pipeline.matchVoiceprints(library) == [1: "佐藤"])
        #expect(pipeline.speakerNames() == [1: "佐藤"])
        #expect(pipeline.speakerCandidates().keys.sorted() == [2] && pipeline.speakerCandidates()[2]?.first?.name == "佐藤", "0.6 は候補。0.2 は何も無い")

        let end = pipeline.finish(reason: .user, endedAt: Date(), at: 15)
        let text = try String(contentsOfFile: try #require(end.transcriptPath), encoding: .utf8)
        #expect(text.contains("相手（佐藤）: 最初の人の話です") && text.contains("相手（話者 2）: 二人目の話です") && text.contains("相手（話者 3）: 三人目の話です"))
        #expect(end.speakers == 3 && sink.kinds.last == "ended")
        #expect(pipeline.nameSpeakers([1: "別の人"]) == .failure(.alreadyNamed(1)), "声紋で付いた名前も、確定済み")
        #expect((try? pipeline.nameSpeakers([2: "鈴木"]).get()) != nil)
    }

    @Test("声の特徴が無い話者は、照合しない。声紋の無い会議（分離だけ）は、これまでどおり")
    func noEmbeddingNoMatch() throws {
        let sink = RecordingSink(), store = SessionStore(root: tempURL("vp-pipeline"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let pipeline = SessionPipeline(title: "会議", sink: sink, store: store)
        pipeline.begin(sources: [.others])
        pipeline.ingest(TranscriptionUpdate(text: "最初の人の話です", isFinal: true, start: 0, end: 4), speaker: .others)
        pipeline.applyVoices([VoiceSegment(speaker: "x", start: 0, end: 5)])
        var library = VoiceprintLibrary(modelRevision: "rev")
        try library.add(name: "佐藤", vector: [1, 0], now: Date())
        #expect(pipeline.matchVoiceprints(library).isEmpty && pipeline.speakerNames().isEmpty && pipeline.voiceEmbedding(of: 1) == nil)
    }
}
