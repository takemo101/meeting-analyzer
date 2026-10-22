import Foundation

/// コマンド 1 つで起動できるエージェント（`meeting-analyzer <名前>`）。
public enum LaunchableAgent: String, CaseIterable, Sendable {
    case claude
    case pi
    case omp
    case opencode

    /// 実行するコマンド名（PATH から探す）。
    public var command: String { rawValue }

}

public enum RegistrationOutcome: Equatable, Sendable {
    /// すでに、このアプリを指して登録されている（何も書かない）。
    case alreadyRegistered(String)
    /// 新しく登録した。`backedUp`：もとのファイルがあり、`*.meeting-analyzer.bak` へ控えた。
    case registered(String, backedUp: Bool)
    /// 別のパス（入れ直した場所など）で登録されていたので、このアプリを指すよう更新した。
    case updated(String, backedUp: Bool)
    /// 安全に編集できなかった（コメントを含む設定など）。手で足してもらう。
    case manual(path: String, reason: String)
}

/// エージェントの設定ファイルへ、このアプリの MCP サーバー（`meeting-analyzer mcp`）を、自動で登録する（`meeting-analyzer pi` など）。
/// 書くのは、`meeting-analyzer` の 1 件だけ。他のキー・並び・インデントは、そのまま。最初の書き込みの前に、元のファイルを `*.meeting-analyzer.bak` へ控える。
/// Claude Code は、起動のたびに、その起動だけに設定を渡すので（`AgentLauncher.mcpConfig`）、設定ファイルは書かない。
enum AgentSetup {
    static let serverName = AgentRegistration.serverName

    /// 設定ファイルの場所。環境変数（各エージェントの設定の置き場所）が優先。`profile`：omp の名前つきプロファイル。
    static func configURL(_ agent: LaunchableAgent, environment: [String: String], profile: String? = nil) -> URL {
        let home = URL(fileURLWithPath: environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory(), isDirectory: true)
        func value(_ name: String) -> String? { environment[name].flatMap { $0.isEmpty ? nil : $0 } }
        switch agent {
        case .claude:
            return home.appendingPathComponent(".claude.json")
        case .pi:
            let directory = value("PI_CODING_AGENT_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".pi/agent", isDirectory: true)
            return directory.appendingPathComponent("mcp.json")
        case .omp:
            let directory: URL
            if let profile = profile ?? value("OMP_PROFILE") ?? value("PI_PROFILE") {
                directory = home.appendingPathComponent(".omp/profiles/\(profile)/agent", isDirectory: true)
            } else if let custom = value("PI_CODING_AGENT_DIR") {
                directory = URL(fileURLWithPath: custom, isDirectory: true)
            } else {
                directory = home.appendingPathComponent("\(value("PI_CONFIG_DIR") ?? ".omp")/agent", isDirectory: true)
            }
            return directory.appendingPathComponent("mcp.json")
        case .opencode:
            let base = value("XDG_CONFIG_HOME").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? home.appendingPathComponent(".config", isDirectory: true)
            let directory = base.appendingPathComponent("opencode", isDirectory: true)
            // 手で書かれた .jsonc だけがあるときは、そちらが本体（コメントを含みうるので、編集せず、手で足してもらう）。
            let json = directory.appendingPathComponent("opencode.json"), jsonc = directory.appendingPathComponent("opencode.jsonc")
            return !FileManager.default.fileExists(atPath: json.path) && FileManager.default.fileExists(atPath: jsonc.path) ? jsonc : json
        }
    }

    /// ルートのオブジェクトの、サーバーを並べるキー。
    static func container(_ agent: LaunchableAgent) -> String { agent == .opencode ? "mcp" : "mcpServers" }

    /// 登録する 1 件（JSON）。形は、各エージェントの設定ファイルの、実際の書式に合わせる。
    static func entryJSON(_ agent: LaunchableAgent, executable: String) -> String {
        let object: [String: Any]
        switch agent {
        case .opencode: object = ["type": "local", "command": [executable, "mcp"], "enabled": true]
        case .omp: object = ["type": "stdio", "command": executable, "args": ["mcp"], "enabled": true]
        default: object = ["command": executable, "args": ["mcp"]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// 登録済みの 1 件が、このアプリを指しているか（コマンドと引数だけを見る。利用者が足した他のキーは、見ない）。
    static func points(to executable: String, _ entry: Any, agent: LaunchableAgent) -> Bool {
        guard let dictionary = entry as? [String: Any] else { return false }
        if agent == .opencode { return dictionary["command"] as? [String] == [executable, "mcp"] }
        return dictionary["command"] as? String == executable && dictionary["args"] as? [String] == ["mcp"]
    }

    static func ensureRegistered(_ agent: LaunchableAgent, executable: String, environment: [String: String], profile: String? = nil) -> RegistrationOutcome {
        let url = configURL(agent, environment: environment, profile: profile)
        let exists = FileManager.default.fileExists(atPath: url.path)
        var text = ""
        if exists {
            guard let data = try? Data(contentsOf: url), let read = String(data: data, encoding: .utf8) else {
                return .manual(path: url.path, reason: "設定ファイルを読めません")
            }
            text = read
        }
        let container = container(agent)
        let current = JSONText.member(in: text, container: container, key: serverName)
        if let current, points(to: executable, current, agent: agent) { return .alreadyRegistered(url.path) }
        guard let updated = JSONText.setMember(in: text, container: container, key: serverName, valueJSON: entryJSON(agent, executable: executable)) else {
            return .manual(path: url.path, reason: "コメントを含む、または読めない形の設定ファイルです")
        }
        var backedUp = false
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
            let backup = url.path + ".meeting-analyzer.bak"
            if exists && !FileManager.default.fileExists(atPath: backup) { try FileManager.default.copyItem(atPath: url.path, toPath: backup); backedUp = true }
            try Data(updated.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: permissions ?? 0o600], ofItemAtPath: url.path)
        } catch {
            return .manual(path: url.path, reason: "設定ファイルを書けません")
        }
        return current == nil ? .registered(url.path, backedUp: backedUp) : .updated(url.path, backedUp: backedUp)
    }
}
