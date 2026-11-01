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
    /// `ACTOR.md` のアクター。無ければ `nil`（「本人」「相手」のまま）。
    public var actor: ActorLabel?
    /// セッションの開始からの秒数（発話の終わり）。分からないときは `nil`。
    public var endedAt: TimeInterval?
    /// 声の分離が付けた、話者 ID（1, 2, …。SPEC §3.14）。会議の終了のときに、確定した「相手」の発話へ付く。無ければ `nil`。
    public var voice: Int?

    public init(id: Int, speaker: Speaker, text: String, isFinal: Bool, startedAt: TimeInterval, version: Int = 1, actor: ActorLabel? = nil, endedAt: TimeInterval? = nil, voice: Int? = nil) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.isFinal = isFinal
        self.startedAt = startedAt
        self.version = version
        self.actor = actor
        self.endedAt = endedAt
        self.voice = voice
    }

    /// 発言者の表示：「相手」・「相手（推定: 佐藤 花子）」・「本人（山田 太郎）」。声で分けたときは、「相手（話者 2）」・「相手（話者 2・推定: 佐藤 花子）」。
    public var speakerLabel: String { speakerLabel(confirmedName: nil) }

    /// `confirmedName`（人間が確定した名前。SPEC §3.15）があれば、「相手（佐藤 花子）」（話者 N・推定の名前より優先する）。
    public func speakerLabel(confirmedName: String?) -> String {
        if let confirmedName { return "\(speaker.displayName)（\(confirmedName)）" }
        var parts: [String] = []
        if let voice { parts.append("話者 \(voice)") }
        if let actor { parts.append(actor.guessed ? "推定: \(actor.name)" : actor.name) }
        return parts.isEmpty ? speaker.displayName : "\(speaker.displayName)（\(parts.joined(separator: "・"))）"
    }

    /// 発言者と番号で一意。バッチ・記録の更新（upsert）に使う。
    public var key: String { "\(speaker.rawValue)-\(id)" }
}
