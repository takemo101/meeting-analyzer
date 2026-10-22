import Foundation

/// エージェントへ渡す、分析のしかたの指示（SPEC §3.11）。解説・提案・サマリーの出し方・書式を、プリセットで選ぶ。
/// ファイル（Markdown）の形：先頭に `---` で囲んだ見出し（`name:` は必須、`description:` は任意）、続けて本文（エージェントへの指示）。
public struct AnalysisPreset: Sendable, Equatable, Identifiable {
    public enum Source: Sendable, Equatable {
        /// アプリに同梱（変更できない。同じ名前のファイルを自分のフォルダに置くと、そちらが優先される）。
        case builtin
        /// 利用者が、自分のフォルダに置いたもの。
        case user
    }

    public enum ParseError: Error, Equatable, Sendable {
        case missingName
        case emptyInstructions
        case tooLong(Int)
    }

    /// 既定のプリセット（同梱の `standard.md`）。
    public static let defaultID = "standard"
    /// 指示の最大文字数。長すぎる指示は、エージェントの文脈を圧迫するので、読まない。
    public static let maxInstructionLength = 8000

    /// ファイル名（拡張子なし）。
    public let id: String
    public let name: String
    public let summary: String
    public let instructions: String
    public let source: Source

    /// `id`：ファイル名（拡張子なし）。`text`：ファイルの内容。
    public static func parse(id: String, text: String, source: Source) -> Result<AnalysisPreset, ParseError> {
        var content = text.replacingOccurrences(of: "\r\n", with: "\n")
        if content.hasPrefix("\u{FEFF}") { content.removeFirst() }
        var fields: [String: String] = [:]
        if content.hasPrefix("---\n"), let end = content.range(of: "\n---", range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex) {
            let header = content[content.index(content.startIndex, offsetBy: 4)..<end.lowerBound]
            for line in header.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            content = String(content[end.upperBound...].drop(while: { $0 != "\n" }))
            guard let name = fields["name"], !name.isEmpty else { return .failure(.missingName) }
        } else {
            fields["name"] = id
        }
        let instructions = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { return .failure(.emptyInstructions) }
        guard instructions.count <= maxInstructionLength else { return .failure(.tooLong(instructions.count)) }
        return .success(AnalysisPreset(id: id, name: fields["name"] ?? id, summary: fields["description"] ?? "", instructions: instructions, source: source))
    }

    /// 開始の出来事（`started`）に載せる形。
    public var info: PresetInfo { PresetInfo(id: id, name: name, instructions: instructions) }
}

/// 開始の出来事（`started`）で、エージェントへ渡す、選んだプリセット。
public struct PresetInfo: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let instructions: String

    public init(id: String, name: String, instructions: String) {
        self.id = id
        self.name = name
        self.instructions = instructions
    }
}
