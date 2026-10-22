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
    static func claudeArguments(userArguments: [String], executable: String, environment: [String: String]) -> [String] {
        userArguments + [
            "--mcp-config", mcpConfig(executable: executable, environment: environment),
            "--dangerously-load-development-channels", "server:\(AgentRegistration.channelServerName)",
        ]
    }

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
