import Foundation

/// エージェントへ、このアプリの MCP サーバー（`mcp`）を登録するための文（コマンド・設定）。実行ファイルのパスは、入れた場所によって変わるので、アプリがその場で作る。
/// `meeting-analyzer pi|omp|opencode` が、設定へ自動で登録できないときに、手で足す文として見せる（エージェントの設定ファイルは、勝手には書き換えない）。
public enum AgentRegistration: CaseIterable, Sendable {
    case claudeCode
    case claudeCodeChannel
    case pi
    case opencode
    case omp

    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .claudeCodeChannel: return "Claude Code（自動で届ける: Channels）"
        case .pi: return "pi"
        case .opencode: return "opencode（opencode.json の mcp に追加）"
        case .omp: return "omp（~/.omp/agent/mcp.json に追加）"
        }
    }

    /// 登録の名前（エージェントの設定に残る）。
    public static let serverName = "meeting-analyzer"
    public static let channelServerName = "meeting-analyzer-channel"

    /// コピーする文。`executable` は、実行ファイルの絶対パス。
    public func text(executable: String) -> String {
        let exe = Self.shellQuote(executable)
        switch self {
        case .claudeCode:
            return "claude mcp add \(Self.serverName) -- \(exe) mcp"
        case .claudeCodeChannel:
            // Channels は、開発用の許可つきの起動が要る。
            return "claude mcp add \(Self.channelServerName) -- \(exe) mcp --channel\nclaude --dangerously-load-development-channels server:\(Self.channelServerName)"
        case .pi:
            return "pi mcp add \(Self.serverName) -- \(exe) mcp"
        case .opencode:
            return Self.opencodeJSON(executable: executable)
        case .omp:
            return Self.ompJSON(executable: executable)
        }
    }

    /// `mcpServers` の 1 件（omp の `mcp.json` に、`mcpServers` の中へ足す）。
    static func ompJSON(executable: String) -> String {
        let object: [String: Any] = ["mcpServers": [serverName: ["type": "stdio", "command": executable, "args": ["mcp"]] as [String: Any]]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// opencode の設定（`opencode.json`）の `mcp` の中へ足す 1 件。**`opencode mcp add` は使わない**：v2.1.2 の書き込みは、`mcp.servers` という入れ子を作り、通常の `mcp.<名前>` の形（利用者が手で書く形）と、揃わない。
    static func opencodeJSON(executable: String) -> String {
        let object: [String: Any] = ["mcp": [serverName: ["type": "local", "command": [executable, "mcp"], "enabled": true] as [String: Any]]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// シェルで、そのまま 1 語として読まれる形（単一引用符で囲み、中の `'` を逃がす）。
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
