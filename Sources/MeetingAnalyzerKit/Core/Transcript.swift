import Foundation

/// セッション全体の記録。発話を upsert で溜め、終了時に、エージェントが読む Markdown にする（SPEC §3.8）。
public struct Transcript: Sendable, Equatable {
    private var byKey: [String: Utterance] = [:]
    /// 撮った画面の画像（会議の開始からの経過秒と、記録のフォルダからの相対パス）。撮った順。
    private var shots: [Shot] = []

    private struct Shot: Sendable, Equatable {
        let offset: TimeInterval
        let path: String
    }

    /// 会議で使った `ACTOR.md` のアクター（SPEC §3.13）。あれば、記録の見出しに書く。
    public var actors: ActorList?

    public init() {}

    public var isEmpty: Bool { byKey.isEmpty }
    public var utteranceCount: Int { byKey.count }

    public mutating func record(_ utterance: Utterance) {
        byKey[utterance.key] = utterance
    }

    /// 撮った画面の画像を、記録へ加える（`path`：`transcript.md` のあるフォルダからの相対パス）。
    public mutating func recordScreenshot(at offset: TimeInterval, path: String) {
        shots.append(Shot(offset: offset, path: path))
    }

    public var screenshotCount: Int { shots.count }

    /// 開始時刻の順。同じ時刻なら、本人 → 相手、番号の順（並びを決まった形にする）。
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

    /// 利用者・エージェントが読む本文。文字起こしは認識の誤りを含み得るので、先頭にそう書く。
    /// `endedAt` が `nil` なら、会議の途中の書き足し（落ちても、そこまでが残る）。撮った画像は、時刻の順に、発話の間へ入れる。
    /// 発話・画像は、空行で区切る（Markdown として表示したとき、1 つの段落に潰れないように）。
    public func markdown(title: String, startedAt: Date, endedAt: Date?) -> String {
        let iso = ISO8601DateFormatter()
        var header = [
            "# 文字起こし",
            "",
            "- 名前: \(title)",
            "- 開始: \(iso.string(from: startedAt))",
        ]
        if let endedAt {
            header.append("- 終了: \(iso.string(from: endedAt))")
            header.append("- 長さ: \(Transcript.clock(endedAt.timeIntervalSince(startedAt)))")
        } else {
            header.append("- 状態: 会議の途中（書き足し中。会議が終わると、整えた記録に書き直す）")
        }
        header.append("- 発話数: \(utteranceCount)")
        if !shots.isEmpty { header.append("- 画像: \(shots.count) 枚") }
        if let actors { header.append("- アクター（ACTOR.md）: \(actors.summary)") }
        let speakerNote = actors == nil
            ? "相手が複数人でも「相手」としか区別できません。"
            : "「相手（推定: 名前）」は、発言の内容から、判断モデルが選んだ推定で、間違い得ます。「相手」のままの発言は、誰か決められなかった（または、判断しなかった）ものです。"
        var blocks = [
            header.joined(separator: "\n"),
            "> 音声認識の自動出力です。誤変換・欠落・聞き取れなかった箇所を含みます。専門用語や固有名詞、数値は特に不確かです。\(speakerNote)",
        ]
        var pending = shots.sorted { $0.offset < $1.offset }[...]
        func image(_ shot: Shot) -> String { "![画面 \(Transcript.clock(shot.offset))](\(shot.path))" }
        for utterance in ordered {
            while let shot = pending.first, shot.offset <= utterance.startedAt {
                blocks.append(image(shot))
                pending.removeFirst()
            }
            blocks.append("[\(Transcript.clock(utterance.startedAt))] \(utterance.speakerLabel): \(utterance.text)")
        }
        for shot in pending { blocks.append(image(shot)) }
        return blocks.joined(separator: "\n\n") + "\n"
    }
}
