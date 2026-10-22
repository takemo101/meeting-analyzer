import Foundation

/// 字幕の 1 件。同じ `id` は、確定するまで、新しい `version` の本文で置き換わる（upsert）。
public struct CaptionUpdate: Codable, Equatable, Sendable {
    /// 発言者と番号で一意（`you-3`、`others-12`）。
    public let id: String
    public let version: Int
    /// 表示名（`本人`・`相手`）。
    public let speaker: String
    /// 流れの種類（`you`＝マイク、`others`＝システム音声）。
    public let source: String
    public let text: String
    /// 発話の開始（エポックからのミリ秒）。
    public let timestamp: Double
    public let isFinal: Bool
}

/// 文字起こしの流れの出来事。エージェントへ渡す JSON の形（SPEC §3.7）。
public enum TranscriptEvent: Equatable, Sendable {
    /// セッションの開始。
    case started(sessionId: String, title: String, startedAt: String, sources: [String])
    /// 字幕のバッチ。`sequence` は 1 から連続する。`screenshot` は、前の送信から画面が変わったときの、画面の JPEG の絶対パス。
    case captions(sessionId: String, sequence: Int, updates: [CaptionUpdate], screenshot: String? = nil)
    /// セッションの終了。エージェントは、これを受けて、サマリーを出す（SPEC §3.8）。
    case ended(sessionId: String, title: String, reason: String, startedAt: String, endedAt: String, durationSeconds: Int, batches: Int, utterances: Int, transcriptPath: String?)

    public var sessionId: String {
        switch self {
        case .started(let id, _, _, _), .captions(let id, _, _, _), .ended(let id, _, _, _, _, _, _, _, _): return id
        }
    }

    public var kind: String {
        switch self {
        case .started: return "started"
        case .captions: return "captions"
        case .ended: return "ended"
        }
    }

    public static func captions(sessionId: UUID, sequence: Int, utterances: [Utterance], sessionStart: Date, screenshot: String? = nil) -> TranscriptEvent {
        let updates = utterances.map { utterance in
            CaptionUpdate(
                id: utterance.key, version: utterance.version, speaker: utterance.speaker.displayName, source: utterance.speaker.rawValue,
                text: utterance.text, timestamp: ((sessionStart.timeIntervalSince1970 + utterance.startedAt) * 1000).rounded(), isFinal: utterance.isFinal
            )
        }
        return .captions(sessionId: sessionId.uuidString.lowercased(), sequence: sequence, updates: updates, screenshot: screenshot)
    }

    public static func started(sessionId: UUID, title: String, startedAt: Date, sources: [Speaker]) -> TranscriptEvent {
        .started(sessionId: sessionId.uuidString.lowercased(), title: title, startedAt: ISO8601DateFormatter().string(from: startedAt), sources: sources.map(\.rawValue))
    }

    public static func ended(
        sessionId: UUID, title: String, reason: EndReason, startedAt: Date, endedAt: Date,
        batches: Int, utterances: Int, transcriptPath: String?
    ) -> TranscriptEvent {
        let iso = ISO8601DateFormatter()
        return .ended(
            sessionId: sessionId.uuidString.lowercased(), title: title, reason: reason.rawValue,
            startedAt: iso.string(from: startedAt), endedAt: iso.string(from: endedAt),
            durationSeconds: max(0, Int(endedAt.timeIntervalSince(startedAt).rounded())),
            batches: batches, utterances: utterances, transcriptPath: transcriptPath
        )
    }
}

extension TranscriptEvent: Codable {
    private enum Key: String, CodingKey {
        case kind, sessionId, title, startedAt, sources, sequence, updates, screenshot, reason, endedAt, durationSeconds, batches, utterances, transcriptPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let sessionId = try c.decode(String.self, forKey: .sessionId)
        switch try c.decode(String.self, forKey: .kind) {
        case "started":
            self = .started(sessionId: sessionId, title: try c.decode(String.self, forKey: .title), startedAt: try c.decode(String.self, forKey: .startedAt), sources: try c.decode([String].self, forKey: .sources))
        case "captions":
            self = .captions(sessionId: sessionId, sequence: try c.decode(Int.self, forKey: .sequence), updates: try c.decode([CaptionUpdate].self, forKey: .updates), screenshot: try c.decodeIfPresent(String.self, forKey: .screenshot))
        case "ended":
            self = .ended(
                sessionId: sessionId, title: try c.decode(String.self, forKey: .title), reason: try c.decode(String.self, forKey: .reason),
                startedAt: try c.decode(String.self, forKey: .startedAt), endedAt: try c.decode(String.self, forKey: .endedAt),
                durationSeconds: try c.decode(Int.self, forKey: .durationSeconds), batches: try c.decode(Int.self, forKey: .batches),
                utterances: try c.decode(Int.self, forKey: .utterances), transcriptPath: try c.decodeIfPresent(String.self, forKey: .transcriptPath)
            )
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "知らない kind: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(sessionId, forKey: .sessionId)
        switch self {
        case .started(_, let title, let startedAt, let sources):
            try c.encode(title, forKey: .title); try c.encode(startedAt, forKey: .startedAt); try c.encode(sources, forKey: .sources)
        case .captions(_, let sequence, let updates, let screenshot):
            try c.encode(sequence, forKey: .sequence); try c.encode(updates, forKey: .updates); try c.encodeIfPresent(screenshot, forKey: .screenshot)
        case .ended(_, let title, let reason, let startedAt, let endedAt, let duration, let batches, let utterances, let path):
            try c.encode(title, forKey: .title); try c.encode(reason, forKey: .reason)
            try c.encode(startedAt, forKey: .startedAt); try c.encode(endedAt, forKey: .endedAt)
            try c.encode(duration, forKey: .durationSeconds); try c.encode(batches, forKey: .batches); try c.encode(utterances, forKey: .utterances)
            try c.encodeIfPresent(path, forKey: .transcriptPath)
        }
    }
}

/// 出来事を受け取る口。実機はハブ（エージェントへ渡す）、テストは記録するだけの偽物。公開は失敗しない（受け手がいなくても、会議は進む）。
public protocol EventSink: Sendable {
    func publish(_ event: TranscriptEvent)
}
