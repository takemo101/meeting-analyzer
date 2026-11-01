import Foundation

/// 文字起こしの更新 → 発話 → バッチ → エージェントへの出来事、そして終了の出来事までの流れ（SPEC §3.6・§3.8）。
/// 入力が「ファイルの再生」でも「マイク・システム音声」でも同じ流れを通す。時計は、更新が持つ秒数（セッションの開始からの経過）を使う。
/// すべて同期で、公開は失敗しない。1 度に 1 つの呼び出しだけが入る前提（`LiveSession` の actor が、それを保つ）。
public final class SessionPipeline: @unchecked Sendable {
    public let sessionId: UUID
    public let title: String
    public let startedAt: Date

    private let sink: any EventSink
    private let store: SessionStore?
    private var batcher: Batcher
    private var transcript = Transcript()
    private var streams: [Speaker: Stream] = [:]
    private var sequence = 0
    private var finished = false
    /// 次のバッチへ添える画面の画像（まだ渡していない最新の 1 枚）。
    private var pendingScreenshot: String?
    /// 会議の途中の書き足し（SPEC §3.8）：書き直す間隔（秒）。`nil` は、書き足さない（ファイルの再生は、失敗したら記録を残さないため、終了のときだけ書く）。
    private let checkpointInterval: TimeInterval?
    /// 前に書いた時刻（会議の開始からの秒）。
    private var lastCheckpoint: TimeInterval?
    /// 前に書いたあとに、記録が変わったか。
    private var dirty = false
    /// 話者 ID ごとの、声の特徴と、声紋の候補（メモリ上だけ。SPEC §3.15）。
    private var voiceEmbeddings: [Int: [Float]] = [:]
    private var voiceCandidates: [Int: [VoiceprintCandidate]] = [:]
    /// 終了の時刻と、終了のときに書いた記録のパス（名付けで、記録を書き直すために覚える）。
    private var endedAt: Date?
    private var finalTranscriptPath: String?
    /// 音声を保存した会議だけ：名付けの写し（`speakers.json`）を書く、分離モデルの版（SPEC §3.16「あとからの名付け」）。`nil` は、書かない。
    private var snapshotRevision: String?

    private struct Stream {
        var currentId = 0
        var lastWasFinal = true
        var version = 0
    }

    /// 選んだ分析のしかた。開始の出来事で、エージェントへ渡す。
    private let preset: PresetInfo?
    /// 使う `ACTOR.md`（SPEC §3.13）。パスは開始の出来事で、名前の一覧は記録の見出しで、渡す。
    private let actors: ActorSource?

    public init(sessionId: UUID = UUID(), title: String, startedAt: Date = Date(), sink: any EventSink, store: SessionStore?, policy: BatchingPolicy = .standard, preset: PresetInfo? = nil, actors: ActorSource? = nil, checkpointInterval: TimeInterval? = nil) {
        self.checkpointInterval = checkpointInterval
        self.preset = preset
        self.actors = actors
        self.sessionId = sessionId
        self.title = title
        self.startedAt = startedAt
        self.sink = sink
        self.store = store
        self.batcher = Batcher(policy: policy)
        self.transcript.actors = actors?.list
    }

    public var utteranceCount: Int { transcript.utteranceCount }

    /// セッションの開始を知らせる（取り込む流れ付き）。
    public func begin(sources: [Speaker]) {
        sink.publish(.started(SessionStart(sessionId: sessionId, title: title, startedAt: startedAt, sources: sources, preset: preset, actorFile: actors?.file)))
    }

    /// 画面の画像を、次のバッチへ添える（渡すまでに、新しい画像が来たら、新しいほうだけ）。**記録には、すべての画像を入れる**
    /// （`relativePath`：`transcript.md` のあるフォルダからの相対パス。`now`：会議の開始からの秒）。
    public func attachScreenshot(path: String, relativePath: String, at now: TimeInterval) {
        guard !finished else { return }
        pendingScreenshot = path
        transcript.recordScreenshot(at: now, path: relativePath)
        dirty = true
    }

    /// 時間だけが進んだとき（更新が来ない間）の確認。静けさが十分なら、溜まった発話を送る。実際の取り込みでは、定期的に呼ぶ。
    public func tick(at now: TimeInterval) {
        guard !finished else { return }
        while let batch = batcher.takeBatch(at: now) { deliver(batch) }
        checkpoint(at: now)
    }

    /// 更新を 1 つ受ける。確定した発話の次の更新は、新しい発話として扱う。送る時になっていれば、送る。
    /// `actor`：この発話に付ける、`ACTOR.md` の本人の名前（「本人」の発話だけ。無ければ「本人」のまま）。
    public func ingest(_ update: TranscriptionUpdate, speaker: Speaker, actor: String? = nil) {
        guard !finished else { return }
        // 前の更新からこの更新までに、静けさが十分あったなら、前の発話は、この更新を混ぜずに送る。
        tick(at: update.end)
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var stream = streams[speaker] ?? Stream()
        if stream.lastWasFinal { stream.currentId += 1; stream.version = 0 }
        stream.version += 1
        stream.lastWasFinal = update.isFinal
        streams[speaker] = stream
        let utterance = Utterance(id: stream.currentId, speaker: speaker, text: text, isFinal: update.isFinal, startedAt: update.start, version: stream.version, actor: actor, endedAt: update.end)
        transcript.record(utterance)
        dirty = true
        batcher.observe(utterance, at: update.end)
        while let batch = batcher.takeBatch(at: update.end) { deliver(batch) }
    }

    /// 一時停止のとき、未送信の発話を出し切る（送るべき時を待たない）。
    public func flushPending(at now: TimeInterval) {
        guard !finished else { return }
        while batcher.hasPending { deliver(batcher.flush(at: now)) }
        checkpoint(at: now, force: true)
    }

    /// 声の分離の結果（会議の時刻に直した区間。SPEC §3.14）を、確定した「相手」の発話へ当てて、話者 ID を付ける。付けた話者の数を返す。
    /// 終了の手順の中（`finish` の前）で、1 回だけ呼ぶ。字幕（すでに送った出来事）は、変えない。記録（`transcript.md`）に反映される。
    /// `embeddings`：分離器の話者の名前ごとの、声の特徴。話者 ID ごとに、メモリ上に持つ（声紋の照合と、名付けのときの「覚える」のため。ファイルへは書かない）。
    @discardableResult
    public func applyVoices(_ segments: [VoiceSegment], embeddings: [String: [Float]] = [:]) -> Int {
        guard !finished else { return 0 }
        let targets = transcript.ordered.filter { $0.speaker == .others && $0.isFinal && ($0.endedAt ?? $0.startedAt) > $0.startedAt }
        let result = VoiceAssignment.assign(spans: targets.map { ($0.startedAt, $0.endedAt ?? $0.startedAt) }, segments: segments)
        for (utterance, id) in zip(targets, result.ids) { transcript.assignVoice(id, forKey: utterance.key) }
        transcript.voiceSpeakers = result.count
        transcript.voiceFound = Set(segments.map(\.speaker)).count
        transcript.voiceUnassigned = result.ids.filter { $0 == nil }.count
        transcript.voiceFailure = nil
        voiceEmbeddings = [:]
        for (index, speaker) in result.speakers.enumerated() { if let embedding = embeddings[speaker] { voiceEmbeddings[index + 1] = embedding } }
        dirty = true
        return result.count
    }

    /// 声紋の照合（SPEC §3.15）：話者ごとの声の特徴を、保存した声紋と比べ、**自動の条件を満たす話者に、名前を付ける**（記録は「相手（名前）」）。
    /// 0.45 以上で、自動でない話者は、候補として覚える（名付けの画面で見せる）。名前を付けた話者 ID と名前を返す。`applyVoices` のあと・`finish` の前に呼ぶ。
    @discardableResult
    public func matchVoiceprints(_ library: VoiceprintLibrary) -> [Int: String] {
        guard !finished else { return [:] }
        var applied: [Int: String] = [:]
        voiceCandidates = [:]
        for (id, embedding) in voiceEmbeddings.sorted(by: { $0.key < $1.key }) {
            let match = library.match(embedding)
            if let automatic = match.automatic {
                transcript.voiceNames[id] = automatic.name
                applied[id] = automatic.name
            } else if !match.candidates.isEmpty {
                voiceCandidates[id] = match.candidates
            }
        }
        if !applied.isEmpty { dirty = true }
        return applied
    }

    /// 会議が終わったあとに、声の分離をやり直した結果を、反映する（SPEC §3.16「再分離」）。確定した「相手」の発話へ、話者 ID を付け直し、**その会議の名前は、すべて外す**
    /// （話者 ID の対応が変わるため。`library` があれば、声紋の照合から、やり直す）。記録を書き直し、`speakers` の出来事（`reseparated`＝これまでの `speakers` は無効。いまの名前のすべて）を出す。
    /// **記録を書き直せなければ、何も変えない**。
    public func reapplyVoices(_ segments: [VoiceSegment], embeddings: [String: [Float]], library: VoiceprintLibrary?, modelRevision: String? = nil) -> Result<SpeakersNamed, SpeakerNamingError> {
        guard finished, let endedAt else { return .failure(.notFinished) }
        var updated = transcript
        let targets = updated.ordered.filter { $0.speaker == .others && $0.isFinal && ($0.endedAt ?? $0.startedAt) > $0.startedAt }
        let result = VoiceAssignment.assign(spans: targets.map { ($0.startedAt, $0.endedAt ?? $0.startedAt) }, segments: segments)
        for (utterance, id) in zip(targets, result.ids) { updated.assignVoice(id, forKey: utterance.key) }
        updated.voiceSpeakers = result.count
        updated.voiceFound = Set(segments.map(\.speaker)).count
        updated.voiceUnassigned = result.ids.filter { $0 == nil }.count
        updated.voiceFailure = nil
        updated.voiceNames = [:]
        var newEmbeddings: [Int: [Float]] = [:]
        for (index, speaker) in result.speakers.enumerated() { if let embedding = embeddings[speaker] { newEmbeddings[index + 1] = embedding } }
        var candidates: [Int: [VoiceprintCandidate]] = [:]
        if let library {
            for (id, embedding) in newEmbeddings.sorted(by: { $0.key < $1.key }) {
                let match = library.match(embedding)
                if let automatic = match.automatic { updated.voiceNames[id] = automatic.name } else if !match.candidates.isEmpty { candidates[id] = match.candidates }
            }
        }
        var path = finalTranscriptPath
        if let store {
            switch store.writeTranscript(updated.markdown(title: title, startedAt: startedAt, endedAt: endedAt), sessionId: sessionId) {
            case .success(let url): path = url.path
            case .failure: return .failure(.writeFailed)
            }
        }
        transcript = updated
        voiceEmbeddings = newEmbeddings
        voiceCandidates = candidates
        finalTranscriptPath = path
        if let modelRevision, snapshotRevision != nil { snapshotRevision = modelRevision }
        persistSnapshot()
        let named = SpeakersNamed(sessionId: sessionId.uuidString.lowercased(), transcriptPath: path, speakers: updated.voiceNames.sorted { $0.key < $1.key }.map { SpeakerName(speaker: $0.key, name: $0.value) }, reseparated: true)
        sink.publish(.speakers(named))
        return .success(named)
    }

    /// 話者 N の声の特徴（「この声を覚える」のため）。分離器が返さなかった話者は `nil`。
    public func voiceEmbedding(of id: Int) -> [Float]? { voiceEmbeddings[id] }

    /// 声紋の候補（話者 N → 候補。類似度の高い順）。
    public func speakerCandidates() -> [Int: [VoiceprintCandidate]] { voiceCandidates }

    /// 確定した名前（話者 N → 名前。声紋で自動に付いたものを含む）。
    public func speakerNames() -> [Int: String] { transcript.voiceNames }

    /// 話者 N の発話の本文（名前のヒントの計算用。長いものから最大 `SpeakerHintMaker.maxTexts` 件）。
    public func speakerTexts(of id: Int) -> [String] { transcript.speakerTexts(of: id, limit: SpeakerHintMaker.maxTexts) }

    /// 声の分離に失敗したことを、記録に書く（話者 ID は付かない）。
    public func noteVoiceFailure(_ reason: String) {
        guard !finished else { return }
        transcript.voiceSpeakers = nil
        transcript.voiceFailure = reason
        dirty = true
    }

    /// 相手の音声を保存できなかったことを、記録に書く（SPEC §3.16）。
    public func noteAudioNotSaved(_ reason: String) {
        guard !finished else { return }
        transcript.audioNote = reason
        dirty = true
    }

    /// 名付けの画面に見せる、話者（話者 N）ごとの要約（SPEC §3.15）。
    public func speakerSummaries() -> [SpeakerSummary] { transcript.speakerSummaries() }

    /// 人間が確定した名前を、話者 N に付ける（SPEC §3.15）：記録（`transcript.md`）を名前つきで書き直し、`speakers` の出来事を出す。
    /// 会議が終わったあとだけ。**記録を書き直せなければ、確定しない**（名前も、出来事も、残さない）。確定した名前は、変えられない。
    public func nameSpeakers(_ requested: [Int: String]) -> Result<SpeakersNamed, SpeakerNamingError> {
        guard finished, let endedAt else { return .failure(.notFinished) }
        guard !requested.isEmpty else { return .failure(.empty) }
        let known = Set(transcript.speakerSummaries().map(\.id))
        var names: [Int: String] = [:]
        for (id, raw) in requested.sorted(by: { $0.key < $1.key }) {
            guard known.contains(id) else { return .failure(.unknownSpeaker(id)) }
            guard transcript.voiceNames[id] == nil else { return .failure(.alreadyNamed(id)) }
            guard let name = SpeakerNameRule.normalize(raw) else { return .failure(.invalidName) }
            names[id] = name
        }
        var updated = transcript
        updated.voiceNames.merge(names) { _, new in new }
        var path = finalTranscriptPath
        if let store {
            switch store.writeTranscript(updated.markdown(title: title, startedAt: startedAt, endedAt: endedAt), sessionId: sessionId) {
            case .success(let url): path = url.path
            case .failure: return .failure(.writeFailed)
            }
        }
        transcript = updated
        finalTranscriptPath = path
        persistSnapshot()
        let named = SpeakersNamed(sessionId: sessionId.uuidString.lowercased(), transcriptPath: path, speakers: names.sorted { $0.key < $1.key }.map { SpeakerName(speaker: $0.key, name: $0.value) })
        sink.publish(.speakers(named))
        return .success(named)
    }

    /// 音声を保存した会議の、名付けの写しを、書くようにする（SPEC §3.16）。`finish` の前に呼ぶ。`modelRevision`：声の特徴を作った分離モデルの版。
    public func keepSnapshot(modelRevision: String) {
        guard !finished else { return }
        snapshotRevision = modelRevision
    }

    /// 名付けの写しを書く（書くようにしていて、記録を書く会議のとき）。**書けなくても、会議・名付けは止めない**（あとから名付けられないだけ）。
    private func persistSnapshot() {
        guard let revision = snapshotRevision, let store, let endedAt else { return }
        let snapshot = SessionSnapshot(sessionId: sessionId, title: title, startedAt: startedAt, endedAt: endedAt, modelRevision: revision, transcript: transcript, embeddings: voiceEmbeddings)
        SavedAudioStore(root: store.root).writeSnapshot(snapshot, sessionId: sessionId)
    }

    /// 終わった会議を、名付けの写しから、元に戻す（SPEC §3.16「あとからの名付け」）。記録の書き直し・`speakers` の出来事は、この会議の `sessionId` で出る。
    /// `currentModelRevision`：いまの分離モデルの版。写しの版と違えば、声の特徴は使わない（「この声を覚える」ができない。声紋と同じ規則）。
    public static func restored(_ snapshot: SessionSnapshot, sink: any EventSink, store: SessionStore, currentModelRevision: String?) -> SessionPipeline? {
        guard let id = UUID(uuidString: snapshot.sessionId) else { return nil }
        let pipeline = SessionPipeline(sessionId: id, title: snapshot.title, startedAt: snapshot.startedDate, sink: sink, store: store)
        pipeline.transcript = snapshot.makeTranscript()
        pipeline.finished = true
        pipeline.endedAt = snapshot.endedDate
        pipeline.finalTranscriptPath = store.transcriptURL(sessionId: id).path
        pipeline.snapshotRevision = snapshot.modelRevision
        if currentModelRevision == snapshot.modelRevision { pipeline.voiceEmbeddings = snapshot.voiceEmbeddings }
        return pipeline
    }

    /// 声紋の候補を、声の特徴と声紋から作り直す（再開した会議で、名前の無い話者の候補を出す。**名前は付けない**）。
    public func refreshCandidates(_ library: VoiceprintLibrary?) {
        voiceCandidates = [:]
        guard let library else { return }
        for (id, embedding) in voiceEmbeddings where transcript.voiceNames[id] == nil {
            let match = library.match(embedding)
            if !match.candidates.isEmpty { voiceCandidates[id] = match.candidates }
            else if let automatic = match.automatic { voiceCandidates[id] = [VoiceprintCandidate(name: automatic.name, similarity: automatic.similarity)] }
        }
    }

    /// 会議の途中の書き足し：変わっていれば、`checkpointInterval` 秒に 1 回まで、記録を書き直す（終了の記録と同じ場所。終了で、整えて書き直す）。
    /// 失敗しても、続ける（終了の記録の失敗は、`ended` の記録のパスが無いことで伝わる）。
    private func checkpoint(at now: TimeInterval, force: Bool = false) {
        guard let store, let checkpointInterval, dirty, !transcript.isEmpty else { return }
        if !force, let last = lastCheckpoint, now - last < checkpointInterval { return }
        lastCheckpoint = now
        dirty = false
        _ = store.writeTranscript(transcript.markdown(title: title, startedAt: startedAt, endedAt: nil), sessionId: sessionId)
    }

    /// セッションを終える。未送信の発話を出し切り、記録を書き、最後に終了の出来事を 1 回だけ出す。出した内容を返す。
    @discardableResult
    public func finish(reason: EndReason, endedAt: Date = Date(), at now: TimeInterval) -> SessionEnd {
        precondition(!finished, "finish は 1 回だけ")
        while batcher.hasPending { deliver(batcher.flush(at: now)) }
        finished = true
        self.endedAt = endedAt
        var transcriptPath: String?
        if let store, !transcript.isEmpty {
            let markdown = transcript.markdown(title: title, startedAt: startedAt, endedAt: endedAt)
            if case .success(let url) = store.writeTranscript(markdown, sessionId: sessionId) { transcriptPath = url.path }
        }
        finalTranscriptPath = transcriptPath
        persistSnapshot()
        let end = SessionEnd(
            sessionId: sessionId, title: title, reason: reason, startedAt: startedAt, endedAt: endedAt,
            batches: sequence, utterances: transcript.utteranceCount, transcriptPath: transcriptPath, speakers: transcript.voiceSpeakers
        )
        sink.publish(.ended(end))
        return end
    }

    private func deliver(_ utterances: [Utterance]) {
        guard !utterances.isEmpty else { return }
        sequence += 1
        sink.publish(.captions(sessionId: sessionId, sequence: sequence, utterances: utterances, sessionStart: startedAt, screenshot: pendingScreenshot))
        pendingScreenshot = nil
    }
}
