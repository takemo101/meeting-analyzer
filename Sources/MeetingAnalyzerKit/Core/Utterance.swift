import Foundation
/// 文字起こしの 1 つの発話。同じ発話は、確定するまで同じ `id` のまま `text` と `version` が更新される。
public struct Utterance: Sendable, Equatable {
    /// 発言者ごとに増える番号。
    public let id: Int
    public let speaker: Speaker
    public var text: String
    /// 認識が確定したか。確定前は後から書き換わる。
    public var isFinal: Bool
    /// セッションの開始からの秒数（発話の開始）。
    public var startedAt: TimeInterval
    /// 本文が変わるたびに 1 ずつ増える（1 から）。
    public var version: Int

    public init(id: Int, speaker: Speaker, text: String, isFinal: Bool, startedAt: TimeInterval, version: Int = 1) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.isFinal = isFinal
        self.startedAt = startedAt
        self.version = version
    }

    /// 発言者と番号で一意。バッチ・記録の更新（upsert）に使う。
    public var key: String { "\(speaker.rawValue)-\(id)" }
}
