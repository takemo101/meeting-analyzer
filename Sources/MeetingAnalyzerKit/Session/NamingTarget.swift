import Foundation

/// 名付けの対象の会議（SPEC §3.15・§3.16）：直前の会議（`LiveSession`）と、あとから開く、音声を保存した過去の会議（`RestoredSession`）を、同じ扱いにする。
/// 名付けの画面・コントローラーは、この口だけを使う。
public protocol NamingTarget: AnyObject, Sendable {
    var sessionId: UUID { get }
    /// 話者（話者 N）ごとの要約。
    func speakerSummaries() async -> [SpeakerSummary]
    /// 人間が確定した名前を、話者 N に付ける（記録を書き直し、`speakers` の出来事を出す）。
    func nameSpeakers(_ names: [Int: String]) async -> Result<SpeakersNamed, SpeakerNamingError>
    /// 確定した名前（声紋で自動に付いたものを含む）。
    func speakerNames() async -> [Int: String]
    /// 話者 N の発話の本文（名前のヒントの計算用）。
    func speakerTexts(of id: Int) async -> [String]
    /// 声紋の候補（自動で付かなかった話者だけ）。
    func speakerCandidates() async -> [Int: [VoiceprintCandidate]]
    /// 話者 N の声の特徴（「この声を覚える」のため）。
    func voiceEmbedding(of id: Int) async -> [Float]?
    /// 保存した音声で、声の分離をやり直す（名前は、すべて外れる）。
    func reseparate(audio: SavedAudioStore, separator: any VoiceSeparating, library: VoiceprintLibrary?, modelRevision: String?) async -> Result<SpeakersNamed, ReseparationError>
}

extension LiveSession: NamingTarget {}

/// 再分離の入力（保存した音声を読んで、分離した結果）。重い処理は、別のスレッドで行う。**記録への反映は、呼び出し側（actor）が行う**。
struct ReseparationInput: Sendable {
    let segments: [VoiceSegment]
    let embeddings: [String: [Float]]

    static func compute(audio: SavedAudioStore, sessionId: UUID, separator: any VoiceSeparating) async -> Result<(ReseparationInput), ReseparationError> {
        let loaded = await Task.detached(priority: .userInitiated) { audio.load(sessionId: sessionId) }.value
        let captured: (samples: [Float], timeline: AudioTimeline)
        switch loaded {
        case .failure(let error): return .failure(.audio(error))
        case .success(let value): captured = value
        }
        do {
            let separation = try await Task.detached(priority: .userInitiated) { try await separator.separate(captured.samples) }.value
            return .success(ReseparationInput(segments: captured.timeline.sessionSegments(from: separation.segments), embeddings: separation.embeddings))
        } catch {
            return .failure(.separation((error as? VoiceSeparationError)?.message ?? String(describing: error)))
        }
    }
}

/// 音声を保存した過去の会議（アプリを終了したあとも）を、名付けの写し（`speakers.json`）から元に戻したもの（SPEC §3.16「あとからの名付け」）。
public actor RestoredSession: NamingTarget {
    public nonisolated let sessionId: UUID
    private let pipeline: SessionPipeline
    private var reseparating = false

    /// `snapshot` から戻す。`currentModelRevision`：いまの分離モデルの版（写しの版と違えば、声の特徴は使わない）。`library`：声紋（あれば、名前の無い話者の候補を作る。名前は付けない）。
    public init?(snapshot: SessionSnapshot, sink: any EventSink, store: SessionStore, currentModelRevision: String?, library: VoiceprintLibrary?) {
        guard let pipeline = SessionPipeline.restored(snapshot, sink: sink, store: store, currentModelRevision: currentModelRevision), let id = UUID(uuidString: snapshot.sessionId) else { return nil }
        pipeline.refreshCandidates(library)
        self.pipeline = pipeline
        sessionId = id
    }

    public func speakerSummaries() -> [SpeakerSummary] { pipeline.speakerSummaries() }
    public func nameSpeakers(_ names: [Int: String]) -> Result<SpeakersNamed, SpeakerNamingError> { pipeline.nameSpeakers(names) }
    public func speakerNames() -> [Int: String] { pipeline.speakerNames() }
    public func speakerTexts(of id: Int) -> [String] { pipeline.speakerTexts(of: id) }
    public func speakerCandidates() -> [Int: [VoiceprintCandidate]] { pipeline.speakerCandidates() }
    public func voiceEmbedding(of id: Int) -> [Float]? { pipeline.voiceEmbedding(of: id) }

    public func reseparate(audio: SavedAudioStore, separator: any VoiceSeparating, library: VoiceprintLibrary?, modelRevision: String?) async -> Result<SpeakersNamed, ReseparationError> {
        guard !reseparating else { return .failure(.busy) }
        reseparating = true
        defer { reseparating = false }
        switch await ReseparationInput.compute(audio: audio, sessionId: sessionId, separator: separator) {
        case .failure(let error): return .failure(error)
        case .success(let input):
            switch pipeline.reapplyVoices(input.segments, embeddings: input.embeddings, library: library, modelRevision: modelRevision) {
            case .success(let named): return .success(named)
            case .failure(let error): return .failure(.naming(error))
            }
        }
    }
}
