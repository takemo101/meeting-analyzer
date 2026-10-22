import Foundation

/// セッション全体の記録。発話を upsert で溜め、終了時に、エージェントが読む Markdown にする（SPEC §3.8）。
public struct Transcript: Sendable, Equatable {
    private var byKey: [String: Utterance] = [:]

    public init() {}

    public var isEmpty: Bool { byKey.isEmpty }
    public var utteranceCount: Int { byKey.count }

    public mutating func record(_ utterance: Utterance) {
        byKey[utterance.key] = utterance
    }

    /// 開始時刻の順。同じ時刻なら、あなた → 相手、番号の順（並びを決まった形にする）。
    public var ordered: [Utterance] {
        byKey.values.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            if $0.speaker != $1.speaker { return $0.speaker == .you }
            return $0.id < $1.id
        }
    }

    /// `mm:ss`（1 時間以上は `h:mm:ss`）。
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// エージェントが読む本文。文字起こしは認識の誤りを含み得るので、先頭にそう書く。
    public func markdown(title: String, startedAt: Date, endedAt: Date) -> String {
        let iso = ISO8601DateFormatter()
        var lines = [
            "# 文字起こし",
            "",
            "- 名前: \(title)",
            "- 開始: \(iso.string(from: startedAt))",
            "- 終了: \(iso.string(from: endedAt))",
            "- 長さ: \(Transcript.clock(endedAt.timeIntervalSince(startedAt)))",
            "- 発話数: \(utteranceCount)",
            "",
            "> 音声認識の自動出力です。誤変換・欠落・聞き取れなかった箇所を含みます。専門用語や固有名詞、数値は特に不確かです。相手が複数人でも「相手」としか区別できません。",
            "",
        ]
        for utterance in ordered {
            lines.append("[\(Transcript.clock(utterance.startedAt))] \(utterance.speaker.displayName): \(utterance.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
