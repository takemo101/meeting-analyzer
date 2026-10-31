import Foundation

/// パイプ向けの出力（機械が読む JSON。1 行 1 件）の形。キーの名前と、省略するキーは、SPEC §3.9 の契約。端末向けの見せ方は `CLIView`。
/// `JSONEncoder`（`.sortedKeys`・`.withoutEscapingSlashes`）で、キーを並べ替えて出す。値が `nil` のキーは、出さない。
enum CLIOutput {
    /// 失敗（標準エラー）。
    struct Failure: Encodable {
        var ok = false
        let code: String
        let message: String
    }

    struct Doctor: Encodable {
        let locale: String
        let supported: Bool
        let installed: Bool
    }

    /// `models` の一覧の 1 件。`kind` は、`transcription`（文字起こし）か `decision`（話者の推定）。
    struct ModelLine: Encodable {
        let kind: String
        let id: String
        let name: String
        let bytes: Int64
        let installed: Bool
        let downloadedBytes: Int64
    }

    /// `models download` の結果。
    struct Downloaded: Encodable {
        var ok = true
        let id: String
        let path: String
    }

    /// `models delete` の結果。
    struct Deleted: Encodable {
        var ok = true
        let id: String
        var deleted = true
    }

    struct PresetLine: Encodable {
        let id: String
        let name: String
        let source: String
        let description: String
    }

    /// 読めなかったプリセットのファイル。
    struct SkippedPreset: Encodable {
        let skipped: String
        let reason: String
    }

    struct ActorLine: Encodable {
        let name: String
        let aliases: [String]
        let topics: [String]
        let isSelf: Bool
        let role: String?

        private enum CodingKeys: String, CodingKey {
            case name, aliases, topics, role
            case isSelf = "self"
        }
    }

    /// `actors check` の結果。
    struct ActorsCheck: Encodable {
        var ok = true
        let path: String
        let actors: [ActorLine]
        let warnings: [String]
    }

    /// `transcribe` の確定した 1 件。
    struct Transcript: Encodable {
        let text: String
        var isFinal = true
        let start: Double
        let end: Double
    }

    /// `replay` の結果。
    struct ReplaySummary: Encodable {
        var ok = true
        let sessionId: String
        let batches: Int
        let utterances: Int
        let durationSeconds: Int
        let transcriptPath: String?
    }

    /// 1 行の JSON にする（エンコードできなければ `{}`）。
    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
