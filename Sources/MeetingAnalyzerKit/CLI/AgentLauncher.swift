import Darwin
import Foundation

/// コーディングエージェントを、このアプリの MCP サーバーつきで、コマンド 1 つで起動する（`meeting-analyzer claude`）。
/// エージェントの設定ファイルは書き換えない。MCP サーバーの設定は、起動のたびに、引数で渡す（その起動だけに効く）。
public enum AgentLauncher {
    /// アプリの bundle ID（アプリが動いていないとき、`open -b` で起動するため）。
    static let bundleID = "dev.takemo101.meeting-analyzer"

    /// その起動だけに効く MCP の設定（JSON）。`--channel` で、字幕を自動で押し込む。
    /// 窓口・データの置き場所を、環境変数で変えているときは、`mcp` にも同じ値を渡す（隔離した検証でも、同じ窓口を見るように）。
    static func mcpConfig(executable: String, environment: [String: String]) -> String {
        var server: [String: Any] = ["command": executable, "args": ["mcp", "--channel"]]
        let forwarded = ["MEETING_ANALYZER_SOCKET", "MEETING_ANALYZER_DATA_DIR"].compactMap { name in
            environment[name].flatMap { $0.isEmpty ? nil : (name, $0) }
        }
        if !forwarded.isEmpty { server["env"] = Dictionary(uniqueKeysWithValues: forwarded) }
        let object: [String: Any] = ["mcpServers": [AgentRegistration.channelServerName: server]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `claude` に渡す引数（コマンド名を除く）。利用者の引数を先頭に置き、こちらの指定を最後に付ける
    /// （`--dangerously-load-development-channels` は、後ろの引数をいくつでも取る形なので、最後でないと、利用者の最初の発言を飲み込む）。
    static func claudeArguments(userArguments: [String], executable: String, environment: [String: String], skillPath: String? = nil) -> [String] {
        userArguments + (skillPath.map { ["--append-system-prompt-file", $0] } ?? []) + [
            "--mcp-config", mcpConfig(executable: executable, environment: environment),
            "--dangerously-load-development-channels", "server:\(AgentRegistration.channelServerName)",
        ]
    }

    /// 起動する引数（コマンド名を除く）。利用者の引数を先頭に置く。skill は、`--append-system-prompt` を持つエージェント（pi・omp）には、そのシステムプロンプトへ足す。
    /// opencode は、skill を、設定の `instructions` で渡す（`opencodeEnvironment`）。
    static func arguments(agent: LaunchableAgent, userArguments: [String], executable: String, environment: [String: String], skillPath: String?, extensionPath: String? = nil) -> [String] {
        switch agent {
        case .claude: return claudeArguments(userArguments: userArguments, executable: executable, environment: environment, skillPath: skillPath)
        case .pi, .omp: return userArguments + (extensionPath.map { ["-e", $0] } ?? []) + (skillPath.map { ["--append-system-prompt", $0] } ?? [])
        case .opencode: return userArguments + (pushesToOpencode(userArguments) ? ["--standalone"] : [])
        }
    }

    /// opencode の、TUI を開かない（サーバーを立てない・管理用の）サブコマンド。`run` と、サブコマンドなし（TUI）だけが、字幕を受ける。
    private static let opencodeOtherSubcommands: Set<String> = [
        "upgrade", "update", "uninstall", "acp", "api", "debug", "auth", "mcp", "plugin", "models", "stats", "mini", "session", "service", "reload", "pair", "serve",
    ]

    /// この起動で、字幕を押し込むプラグインを載せるか（TUI と `run` だけ。`mcp list` などの管理コマンドには載せない）。
    static func pushesToOpencode(_ userArguments: [String]) -> Bool {
        guard let first = userArguments.first else { return true }
        return !opencodeOtherSubcommands.contains(first)
    }

    /// opencode に、その起動だけ、字幕を押し込むプラグインと skill を載せる（環境変数 `OPENCODE_CONFIG_CONTENT`。設定ファイルは書き換えない。
    /// 利用者の設定・プラグインとは、足し合わされる）。利用者がすでに `OPENCODE_CONFIG_CONTENT` を設定していれば、その `plugin`・`instructions` に足す。
    /// 既存の値が JSON のオブジェクトでなければ、壊さないよう、何も足さない。
    /// opencode は、既定では、共有のバックグラウンドサービスで動き、この環境変数が届かない。そのため、起動の引数に `--standalone`（専用のサーバー）を付ける。
    static func opencodeEnvironment(existing: String?, pluginPath: String?, skillPath: String?) -> [String: String] {
        guard let pluginPath else { return [:] }
        var object: [String: Any] = [:]
        if let existing, !existing.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: Data(existing.utf8))) as? [String: Any] else { return [:] }
            object = parsed
        }
        func appended(_ key: String, _ value: String) {
            var list = (object[key] as? [Any]) ?? []
            if !list.contains(where: { ($0 as? String) == value }) { list.append(value) }
            object[key] = list
        }
        appended("plugin", pluginPath)
        if let skillPath { appended("instructions", skillPath) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return [:] }
        return ["OPENCODE_CONFIG_CONTENT": String(decoding: data, as: UTF8.self)]
    }

    /// omp の名前つきプロファイル（`--profile X`／`--profile=X`）。設定ファイルの場所が変わる。
    static func profile(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == "--profile", index + 1 < arguments.count { return arguments[index + 1] }
            if argument.hasPrefix("--profile=") { return String(argument.dropFirst("--profile=".count)) }
        }
        return nil
    }

    static func bundledSkillPath(executable: String) -> String? { BundledResources.path("SKILL.md", executable: executable) }

    /// pi・omp に、字幕を押し込む拡張（`Contents/Resources/meeting-analyzer-pi.js`）。
    static func bundledExtensionPath(executable: String) -> String? { BundledResources.path("meeting-analyzer-pi.js", executable: executable) }

    /// opencode に、字幕を押し込むプラグイン（`Contents/Resources/meeting-analyzer-opencode/`。ディレクトリ）。
    static func bundledOpencodePluginPath(executable: String) -> String? { BundledResources.path("meeting-analyzer-opencode", executable: executable) }

    /// 窓口の場所を、環境変数で変えているときは、検証・隔離のための起動とみなす（実際のアプリは、起動しない）。
    static func usesDefaultHub(environment: [String: String]) -> Bool {
        ["MEETING_ANALYZER_SOCKET", "MEETING_ANALYZER_DATA_DIR"].allSatisfy { (environment[$0] ?? "").isEmpty }
    }

    /// アプリ（窓口）が動いていなければ、入れてあるアプリを起動して、窓口が開くのを待つ。起動できなくても、エージェントは起動する
    /// （`mcp` が、つなぎ直す）。戻り値は、窓口が使える状態か。
    @discardableResult
    static func ensureAppRunning(environment: [String: String], wait: TimeInterval = 8, launch: () -> Bool = launchInstalledApp) -> Bool {
        let socket = RuntimePaths.hubSocket(environment: environment)
        if HubServer.canConnect(path: socket) { return true }
        guard usesDefaultHub(environment: environment), launch() else { return false }
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if HubServer.canConnect(path: socket) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// 入れてあるアプリを、`open -b` で起動する（`just install` で入れた場所を、LaunchServices が bundle ID から探す）。
    static func launchInstalledApp() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// このプロセスを、エージェントに置き換える（標準入出力・端末・シグナルは、そのまま引き継がれる）。戻るのは、失敗したときだけ。戻り値は errno。
    public static func replaceProcess(command: String, arguments: [String]) -> Int32 {
        let argv: [UnsafeMutablePointer<CChar>?] = ([command] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        execvp(command, argv)
        return errno
    }
}
