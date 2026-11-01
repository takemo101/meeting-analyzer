import Foundation

/// 終わった会議の、名付けを再開するための写し（SPEC §3.16「あとからの名付け」）。音声を保存した会議だけ、記録と同じフォルダに置く（`speakers.json`。0600）。
/// 中身：発話（本文・時刻・話者 ID）・撮った画像の位置・確定した名前・話者ごとの声の特徴（「この声を覚える」のため）・分離のモデルの版。**音声は含まない**。
/// 記録（`transcript.md`）と同じ寿命で消え、「保存した音声をすべて削除」でも消える。
public struct SessionSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public struct UtteranceRecord: Codable, Sendable, Equatable {
        public var id: Int
        public var speaker: String
        public var text: String
        public var isFinal: Bool
        public var startedAt: TimeInterval
        public var version: Int
        public var actor: String?
        public var endedAt: TimeInterval?
        public var voice: Int?
    }

    public struct ShotRecord: Codable, Sendable, Equatable {
        public var offset: TimeInterval
        public var path: String
    }

    public var version: Int
    public var sessionId: String
    public var title: String
    /// 1970 年からの秒。
    public var startedAt: TimeInterval
    public var endedAt: TimeInterval
    /// 声の特徴を作った分離モデルの版。いまの版と違えば、声の特徴は使わない（声紋と同じ規則）。
    public var modelRevision: String
    public var utterances: [UtteranceRecord]
    public var shots: [ShotRecord]
    public var actorsSummary: String?
    public var voiceSpeakers: Int?
    public var voiceFound: Int?
    public var voiceUnassigned: Int?
    public var voiceFailure: String?
    public var audioNote: String?
    /// 話者 N → 確定した名前（JSON のキーは文字列）。
    public var voiceNames: [String: String]
    /// 話者 N → 声の特徴。
    public var embeddings: [String: [Float]]

    /// 終わった会議の写しを作る。
    public init(sessionId: UUID, title: String, startedAt: Date, endedAt: Date, modelRevision: String, transcript: Transcript, embeddings: [Int: [Float]]) {
        let content = transcript.snapshotContent()
        version = Self.currentVersion
        self.sessionId = sessionId.uuidString.lowercased()
        self.title = title
        self.startedAt = startedAt.timeIntervalSince1970
        self.endedAt = endedAt.timeIntervalSince1970
        self.modelRevision = modelRevision
        utterances = content.utterances.map {
            UtteranceRecord(id: $0.id, speaker: $0.speaker.rawValue, text: $0.text, isFinal: $0.isFinal, startedAt: $0.startedAt, version: $0.version, actor: $0.actor, endedAt: $0.endedAt, voice: $0.voice)
        }
        shots = content.shots.map { ShotRecord(offset: $0.offset, path: $0.path) }
        actorsSummary = transcript.actors?.summary ?? transcript.actorsSummary
        voiceSpeakers = transcript.voiceSpeakers
        voiceFound = transcript.voiceFound
        voiceUnassigned = transcript.voiceUnassigned
        voiceFailure = transcript.voiceFailure
        audioNote = transcript.audioNote
        voiceNames = Dictionary(uniqueKeysWithValues: transcript.voiceNames.map { (String($0.key), $0.value) })
        self.embeddings = Dictionary(uniqueKeysWithValues: embeddings.map { (String($0.key), $0.value) })
    }

    /// 記録に戻す。知らない話者の種類の発話は、除く。
    public func makeTranscript() -> Transcript {
        var transcript = Transcript(
            utterances: utterances.compactMap { record in
                guard let speaker = Speaker(rawValue: record.speaker) else { return nil }
                return Utterance(id: record.id, speaker: speaker, text: record.text, isFinal: record.isFinal, startedAt: record.startedAt, version: record.version, actor: record.actor, endedAt: record.endedAt, voice: record.voice)
            },
            shots: shots.map { ($0.offset, $0.path) }
        )
        transcript.actorsSummary = actorsSummary
        transcript.voiceSpeakers = voiceSpeakers
        transcript.voiceFound = voiceFound
        transcript.voiceUnassigned = voiceUnassigned
        transcript.voiceFailure = voiceFailure
        transcript.audioNote = audioNote
        transcript.voiceNames = Dictionary(uniqueKeysWithValues: voiceNames.compactMap { key, name in Int(key).map { ($0, name) } })
        return transcript
    }

    /// 話者 N → 声の特徴。
    public var voiceEmbeddings: [Int: [Float]] {
        Dictionary(uniqueKeysWithValues: embeddings.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    public var startedDate: Date { Date(timeIntervalSince1970: startedAt) }
    public var endedDate: Date { Date(timeIntervalSince1970: endedAt) }
}
