import Foundation

/// ブリッジ（エージェント側の受信口）へ送る、字幕のバッチ。形は live-support の `/captions` と同じ（SPEC §3.7）。
public struct CaptionBatch: Encodable, Equatable, Sendable {
    public struct Update: Encodable, Equatable, Sendable {
        public let messageId: String
        public let messageVersion: Int
        public let speakerName: String
        public let transcript: String
        /// 発話の開始時刻（エポックからのミリ秒）。
        public let timestamp: Double
        public let version: Int
        public let deviceId: String
    }

    public let sessionId: String
    public let sequence: Int
    public let meetingId: String
    /// 取得元の種類。このアプリは常に `Mac`。
    public let platform: String
    public let updates: [Update]

    public static let platformName = "Mac"

    public static func make(sessionId: UUID, sequence: Int, meetingId: String, utterances: [Utterance], sessionStart: Date) -> CaptionBatch {
        let updates = utterances.map { utterance in
            Update(
                messageId: utterance.key,
                messageVersion: utterance.version,
                speakerName: utterance.speaker.displayName,
                transcript: utterance.text,
                timestamp: ((sessionStart.timeIntervalSince1970 + utterance.startedAt) * 1000).rounded(),
                version: utterance.version,
                deviceId: utterance.speaker.rawValue
            )
        }
        return CaptionBatch(sessionId: sessionId.uuidString.lowercased(), sequence: sequence, meetingId: meetingId, platform: platformName, updates: updates)
    }
}

/// 会議の終了の合図。エージェントは、これを受けて、プロジェクトの内容を元に詳細なサマリーを出す（SPEC §3.8）。
public struct EndEvent: Encodable, Equatable, Sendable {
    public let sessionId: String
    public let meetingId: String
    public let platform: String
    public let reason: String
    public let startedAt: String
    public let endedAt: String
    public let durationSeconds: Int
    public let batches: Int
    public let utterances: Int
    /// 会議全体の文字起こし（Markdown）の絶対パス。書けなかったときは無し。
    public let transcriptPath: String?

    public static func make(
        sessionId: UUID, meetingId: String, reason: EndReason, startedAt: Date, endedAt: Date,
        batches: Int, utterances: Int, transcriptPath: String?
    ) -> EndEvent {
        let iso = ISO8601DateFormatter()
        return EndEvent(
            sessionId: sessionId.uuidString.lowercased(), meetingId: meetingId, platform: CaptionBatch.platformName,
            reason: reason.rawValue, startedAt: iso.string(from: startedAt), endedAt: iso.string(from: endedAt),
            durationSeconds: max(0, Int(endedAt.timeIntervalSince(startedAt).rounded())), batches: batches, utterances: utterances,
            transcriptPath: transcriptPath
        )
    }
}
