import Foundation
import Testing
@testable import MeetingAnalyzerKit

private func tempHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ma-home-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let exe = "/Users/me/Applications/MeetingAnalyzer.app/Contents/MacOS/MeetingAnalyzer"

@Suite("AgentSetup: エージェントの設定への、MCP サーバーの自動登録")
struct AgentSetupTests {
    @Test("設定ファイルの場所：環境変数が優先で、なければ各エージェントの既定の場所")
    func paths() {
        let env = ["HOME": "/h"]
        #expect(AgentSetup.configURL(.pi, environment: env).path == "/h/.pi/agent/mcp.json")
        #expect(AgentSetup.configURL(.pi, environment: env.merging(["PI_CODING_AGENT_DIR": "/p"]) { $1 }).path == "/p/mcp.json")
        #expect(AgentSetup.configURL(.omp, environment: env).path == "/h/.omp/agent/mcp.json")
        #expect(AgentSetup.configURL(.omp, environment: env.merging(["PI_CODING_AGENT_DIR": "/p"]) { $1 }).path == "/p/mcp.json")
        #expect(AgentSetup.configURL(.omp, environment: env.merging(["PI_CONFIG_DIR": ".omp-x"]) { $1 }).path == "/h/.omp-x/agent/mcp.json")
        #expect(AgentSetup.configURL(.omp, environment: env, profile: "work").path == "/h/.omp/profiles/work/agent/mcp.json", "プロファイルは、PI_CODING_AGENT_DIR より優先")
        #expect(AgentSetup.configURL(.omp, environment: env.merging(["OMP_PROFILE": "w", "PI_CODING_AGENT_DIR": "/p"]) { $1 }).path == "/h/.omp/profiles/w/agent/mcp.json")
        #expect(AgentSetup.configURL(.agy, environment: env).path == "/h/.gemini/config/mcp_config.json")
        #expect(AgentSetup.configURL(.opencode, environment: env).path == "/h/.config/opencode/opencode.json")
        #expect(AgentSetup.configURL(.opencode, environment: env.merging(["XDG_CONFIG_HOME": "/x"]) { $1 }).path == "/x/opencode/opencode.json")
    }

    @Test("エントリの形は、各エージェントの設定の書式（pi・agy：command と args／omp：type つき／opencode：mcp の map、command は配列）")
    func entryShapes() throws {
        func object(_ agent: LaunchableAgent) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: Data(AgentSetup.entryJSON(agent, executable: exe).utf8)) as? [String: Any]) }
        for agent in [LaunchableAgent.pi, .agy] {
            let entry = try object(agent)
            #expect(entry["command"] as? String == exe && entry["args"] as? [String] == ["mcp"] && entry["type"] == nil)
        }
        let omp = try object(.omp)
        #expect(omp["type"] as? String == "stdio" && omp["command"] as? String == exe && omp["args"] as? [String] == ["mcp"] && omp["enabled"] as? Bool == true)
        let opencode = try object(.opencode)
        #expect(opencode["type"] as? String == "local" && opencode["command"] as? [String] == [exe, "mcp"] && opencode["enabled"] as? Bool == true)
        #expect(AgentSetup.container(.opencode) == "mcp" && AgentSetup.container(.pi) == "mcpServers")
    }

    @Test("設定ファイルが無ければ作り、あるなら、他の内容を残して 1 件だけ足す。2 回目は何も書かない")
    func registerOnce() throws {
        for agent in [LaunchableAgent.pi, .omp, .agy, .opencode] {
            let home = try tempHome()
            defer { try? FileManager.default.removeItem(at: home) }
            let env = ["HOME": home.path]
            let url = AgentSetup.configURL(agent, environment: env)

            #expect(AgentSetup.ensureRegistered(agent, executable: exe, environment: env) == .registered(url.path, backedUp: false), "\(agent)")
            #expect(AgentSetup.points(to: exe, try #require(JSONText.member(in: String(contentsOf: url, encoding: .utf8), container: AgentSetup.container(agent), key: "meeting-analyzer")), agent: agent))
            #expect((try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o700, "新しく作るディレクトリは、本人だけ")

            let before = try Data(contentsOf: url)
            #expect(AgentSetup.ensureRegistered(agent, executable: exe, environment: env) == .alreadyRegistered(url.path))
            #expect(try Data(contentsOf: url) == before, "登録済みなら、書き換えない")
            #expect(!FileManager.default.fileExists(atPath: url.path + ".meeting-analyzer.bak"), "元のファイルが無かったので、控えも無い")
        }
    }

    @Test("既存の設定は、他のキー・並び・権限を保ち、最初の書き込みの前に、元のファイルを控える。入れ直しで場所が変われば、更新する")
    func preservesExistingAndUpdates() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["HOME": home.path]
        let url = AgentSetup.configURL(.opencode, environment: env)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "{\n    \"$schema\": \"https://opencode.ai/config.json\",\n    \"mcp\": {\n        \"mikan\": {\"type\": \"local\", \"command\": [\"mikan\", \"mcp\"]}\n    },\n    \"plugin\": [\"x\"]\n}\n"
        try Data(original.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        #expect(AgentSetup.ensureRegistered(.opencode, executable: exe, environment: env) == .registered(url.path, backedUp: true))
        let first = try String(contentsOf: url, encoding: .utf8)
        #expect(first.contains("\"$schema\": \"https://opencode.ai/config.json\"") && first.contains("\"plugin\": [\"x\"]") && first.contains("\"mikan\""))
        #expect(try String(contentsOfFile: url.path + ".meeting-analyzer.bak", encoding: .utf8) == original, "元のファイルを控える")
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o644, "権限を保つ")

        let moved = "/Users/me/Elsewhere/MeetingAnalyzer"
        #expect(AgentSetup.ensureRegistered(.opencode, executable: moved, environment: env) == .updated(url.path, backedUp: false))
        let second = try String(contentsOf: url, encoding: .utf8)
        #expect(second.contains(moved) && !second.contains(exe), "古い場所は、置き換わる")
        #expect(try String(contentsOfFile: url.path + ".meeting-analyzer.bak", encoding: .utf8) == original, "控えは、最初の 1 回だけ（最初の元のファイルのまま）")
        #expect(second.contains("\"plugin\": [\"x\"]"))
    }

    @Test("利用者が足した他のキー（env など）があっても、コマンドと引数が合っていれば、登録済みとする")
    func extraKeysAreKept() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["HOME": home.path]
        let url = AgentSetup.configURL(.pi, environment: env)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"mcpServers\": {\"meeting-analyzer\": {\"command\": \"\(exe)\", \"args\": [\"mcp\"], \"env\": {\"A\": \"1\"}}}}".utf8).write(to: url)
        #expect(AgentSetup.ensureRegistered(.pi, executable: exe, environment: env) == .alreadyRegistered(url.path))
    }

    @Test("コメントつきの設定（JSONC）・読めない形は、書かず、手で足す案内にする")
    func manualWhenUnsafe() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let env = ["HOME": home.path]
        let url = AgentSetup.configURL(.omp, environment: env)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let commented = "{\n  // my servers\n  \"mcpServers\": {}\n}\n"
        try Data(commented.utf8).write(to: url)
        guard case .manual(let path, _) = AgentSetup.ensureRegistered(.omp, executable: exe, environment: env) else { Issue.record("not manual"); return }
        #expect(path == url.path)
        #expect(try String(contentsOf: url, encoding: .utf8) == commented, "書き換えない")
        #expect(!FileManager.default.fileExists(atPath: url.path + ".meeting-analyzer.bak"))

        // opencode：opencode.jsonc だけがあるときは、そちらが本体で、手で足す。
        let oc = AgentSetup.configURL(.opencode, environment: env)
        try FileManager.default.createDirectory(at: oc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ /* c */ }".utf8).write(to: oc.deletingLastPathComponent().appendingPathComponent("opencode.jsonc"))
        let target = AgentSetup.configURL(.opencode, environment: env)
        #expect(target.lastPathComponent == "opencode.jsonc")
        guard case .manual = AgentSetup.ensureRegistered(.opencode, executable: exe, environment: env) else { Issue.record("jsonc not manual"); return }
    }

    @Test("omp の --profile は、引数から読む。pi・omp には skill を、システムプロンプトへ足す。agy・opencode には足さない")
    func launchArguments() {
        #expect(AgentLauncher.profile(in: ["x", "--profile", "work"]) == "work")
        #expect(AgentLauncher.profile(in: ["--profile=dev"]) == "dev")
        #expect(AgentLauncher.profile(in: ["--profile"]) == nil)
        #expect(AgentLauncher.profile(in: ["a"]) == nil)
        let skill = "/App/Contents/Resources/SKILL.md"
        let extensionFile = "/App/Contents/Resources/meeting-analyzer-pi.js"
        #expect(AgentLauncher.arguments(agent: .pi, userArguments: ["hello"], executable: exe, environment: [:], skillPath: skill, extensionPath: extensionFile) == ["hello", "-e", extensionFile, "--append-system-prompt", skill])
        #expect(AgentLauncher.arguments(agent: .omp, userArguments: [], executable: exe, environment: [:], skillPath: skill, extensionPath: extensionFile) == ["-e", extensionFile, "--append-system-prompt", skill])
        #expect(AgentLauncher.arguments(agent: .agy, userArguments: [], executable: exe, environment: [:], skillPath: skill, extensionPath: extensionFile) == [], "拡張は、pi・omp だけ")
        #expect(AgentLauncher.arguments(agent: .opencode, userArguments: ["hello"], executable: exe, environment: [:], skillPath: skill, extensionPath: extensionFile) == ["hello", "--standalone"], "opencode は、専用のサーバーで動かす（利用者の引数が先頭）")
        #expect(AgentLauncher.arguments(agent: .opencode, userArguments: ["run", "要約して"], executable: exe, environment: [:], skillPath: skill) == ["run", "要約して", "--standalone"])
        #expect(AgentLauncher.arguments(agent: .opencode, userArguments: ["mcp", "list"], executable: exe, environment: [:], skillPath: skill) == ["mcp", "list"], "管理コマンドには、載せない")
        #expect(AgentLauncher.arguments(agent: .agy, userArguments: ["-c"], executable: exe, environment: [:], skillPath: skill) == ["-c"])
        #expect(AgentLauncher.arguments(agent: .opencode, userArguments: [], executable: exe, environment: [:], skillPath: skill) == ["--standalone"])
        #expect(AgentLauncher.arguments(agent: .pi, userArguments: ["hello"], executable: exe, environment: [:], skillPath: nil) == ["hello"])
    }
}


@Suite("opencode: プラグインと skill を、その起動だけに載せる")
struct OpencodeLaunchTests {
    private func object(_ environment: [String: String]) -> [String: Any]? {
        environment["OPENCODE_CONFIG_CONTENT"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    @Test("何も設定していなければ、プラグインと skill だけの設定を渡す")
    func fresh() {
        let result = object(AgentLauncher.opencodeEnvironment(existing: nil, pluginPath: "/App/plugin", skillPath: "/App/SKILL.md"))
        #expect(result?["plugin"] as? [String] == ["/App/plugin"])
        #expect(result?["instructions"] as? [String] == ["/App/SKILL.md"])
    }

    @Test("利用者が OPENCODE_CONFIG_CONTENT を設定していれば、その内容を残して足す（重ねて足さない）")
    func mergesExisting() {
        let existing = #"{"plugin":["user-plugin"],"model":"a/b"}"#
        let once = AgentLauncher.opencodeEnvironment(existing: existing, pluginPath: "/App/plugin", skillPath: nil)
        let result = object(once)
        #expect(result?["plugin"] as? [String] == ["user-plugin", "/App/plugin"])
        #expect(result?["model"] as? String == "a/b")
        #expect(result?["instructions"] == nil)
        let twice = AgentLauncher.opencodeEnvironment(existing: once["OPENCODE_CONFIG_CONTENT"], pluginPath: "/App/plugin", skillPath: nil)
        #expect(object(twice)?["plugin"] as? [String] == ["user-plugin", "/App/plugin"])
    }

    @Test("既存の値が JSON のオブジェクトでなければ、壊さないよう、何も足さない。プラグインが同梱されていなくても、何も足さない")
    func leavesInvalidAlone() {
        #expect(AgentLauncher.opencodeEnvironment(existing: "not json", pluginPath: "/App/plugin", skillPath: nil).isEmpty)
        #expect(AgentLauncher.opencodeEnvironment(existing: "[1]", pluginPath: "/App/plugin", skillPath: nil).isEmpty)
        #expect(AgentLauncher.opencodeEnvironment(existing: nil, pluginPath: nil, skillPath: "/App/SKILL.md").isEmpty)
    }

    @Test("起動の判定：TUI と run だけが載せる。管理コマンドは載せない")
    func which() {
        for arguments in [[], ["run", "x"], ["~/project"], ["--continue"]] { #expect(AgentLauncher.pushesToOpencode(arguments), "\(arguments)") }
        for arguments in [["mcp", "list"], ["auth", "login"], ["serve"], ["plugin", "list"]] { #expect(!AgentLauncher.pushesToOpencode(arguments), "\(arguments)") }
    }
}
