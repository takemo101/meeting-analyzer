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
    /// `ACTOR.md` のアクターの名前（SPEC §3.13）。無ければ省く。`speaker` は、これがあっても `本人`・`相手` のまま。
    public var actor: String? = nil
    /// `actor` が、内容から選んだ推定か（`true`）。`本人` を `ACTOR.md` の本人へ対応づけたときは `false`。`actor` が無いときは省く。
    public var actorGuessed: Bool? = nil
}

/// セッションの開始の内容。`preset` は、本人が選んだ、この会話の分析のしかた（SPEC §3.11）。`actorFile` は、本人が選んだ `ACTOR.md` の絶対パス（SPEC §3.13）。
public struct SessionStart: Codable, Equatable, Sendable {
    public let sessionId: String
    public let title: String
    public let startedAt: String
    public let sources: [String]
    public let preset: PresetInfo?
    public let actorFile: String?

    public init(sessionId: String, title: String, startedAt: String, sources: [String], preset: PresetInfo? = nil, actorFile: String? = nil) {
        self.sessionId = sessionId
        self.title = title
        self.startedAt = startedAt
        self.sources = sources
        self.preset = preset
        self.actorFile = actorFile
    }

    /// セッションの値（UUID・日時・発言者）から、JSON の形（小文字の UUID・ISO 8601）にして作る。
    public init(sessionId: UUID, title: String, startedAt: Date, sources: [Speaker], preset: PresetInfo? = nil, actorFile: String? = nil) {
        self.init(sessionId: sessionId.uuidString.lowercased(), title: title, startedAt: ISO8601DateFormatter().string(from: startedAt), sources: sources.map(\.rawValue), preset: preset, actorFile: actorFile)
    }
}

/// セッションの終了の内容。エージェントは、これを受けて、サマリーを出す（SPEC §3.8）。
public struct SessionEnd: Codable, Equatable, Sendable {
    public let sessionId: String
    public let title: String
    public let reason: String
    public let startedAt: String
    public let endedAt: String
    public let durationSeconds: Int
    public let batches: Int
    public let utterances: Int
    /// 記録（Markdown）の絶対パス。書けなかったときは無し。
    public let transcriptPath: String?

    public init(sessionId: String, title: String, reason: String, startedAt: String, endedAt: String, durationSeconds: Int, batches: Int, utterances: Int, transcriptPath: String?) {
        self.sessionId = sessionId
        self.title = title
        self.reason = reason
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.batches = batches
        self.utterances = utterances
        self.transcriptPath = transcriptPath
    }

    /// セッションの値（UUID・日時・終了の理由）から、JSON の形にして作る。`durationSeconds` は、開始から終了までの秒（負にならない）。
    public init(sessionId: UUID, title: String, reason: EndReason, startedAt: Date, endedAt: Date, batches: Int, utterances: Int, transcriptPath: String?) {
        let iso = ISO8601DateFormatter()
        self.init(
            sessionId: sessionId.uuidString.lowercased(), title: title, reason: reason.rawValue,
            startedAt: iso.string(from: startedAt), endedAt: iso.string(from: endedAt),
            durationSeconds: max(0, Int(endedAt.timeIntervalSince(startedAt).rounded())),
            batches: batches, utterances: utterances, transcriptPath: transcriptPath
        )
    }
}

/// 文字起こしの流れの出来事。エージェントへ渡す JSON の形（SPEC §3.7）。
public enum TranscriptEvent: Equatable, Sendable {
    case started(SessionStart)
    /// 字幕のバッチ。`sequence` は 1 から連続する。`screenshot` は、前の送信から画面が変わったときの、画面の JPEG の絶対パス。
    case captions(sessionId: String, sequence: Int, updates: [CaptionUpdate], screenshot: String? = nil)
    case ended(SessionEnd)

    public var sessionId: String {
        switch self {
        case .started(let start): return start.sessionId
        case .captions(let id, _, _, _): return id
        case .ended(let end): return end.sessionId
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
                text: utterance.text, timestamp: ((sessionStart.timeIntervalSince1970 + utterance.startedAt) * 1000).rounded(), isFinal: utterance.isFinal,
                actor: utterance.actor?.name, actorGuessed: utterance.actor?.guessed
            )
        }
        return .captions(sessionId: sessionId.uuidString.lowercased(), sequence: sequence, updates: updates, screenshot: screenshot)
    }
}

/// JSON は、`kind` と、その種類の項目を、同じ階層に並べる（`started`・`ended` は、内容の型が、自分の項目を読み書きする）。
extension TranscriptEvent: Codable {
    private enum Key: String, CodingKey {
        case kind, sessionId, sequence, updates, screenshot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "started": self = .started(try SessionStart(from: decoder))
        case "captions":
            self = .captions(sessionId: try c.decode(String.self, forKey: .sessionId), sequence: try c.decode(Int.self, forKey: .sequence), updates: try c.decode([CaptionUpdate].self, forKey: .updates), screenshot: try c.decodeIfPresent(String.self, forKey: .screenshot))
        case "ended": self = .ended(try SessionEnd(from: decoder))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "知らない kind: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .started(let start): try start.encode(to: encoder)
        case .captions(let id, let sequence, let updates, let screenshot):
            try c.encode(id, forKey: .sessionId)
            try c.encode(sequence, forKey: .sequence); try c.encode(updates, forKey: .updates); try c.encodeIfPresent(screenshot, forKey: .screenshot)
        case .ended(let end): try end.encode(to: encoder)
        }
    }
}

/// 出来事を受け取る口。実機はハブ（エージェントへ渡す）、テストは記録するだけの偽物。公開は失敗しない（受け手がいなくても、会議は進む）。
public protocol EventSink: Sendable {
    func publish(_ event: TranscriptEvent)
}
