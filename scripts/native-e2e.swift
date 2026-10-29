#!/usr/bin/swift
// meeting-analyzer native E2E（verifying-macos-apps 準拠）。自分で起動したプロセスだけを操作する。
// 使い方（リポジトリのルートで）:
//   /usr/bin/swift scripts/native-e2e.swift "$PWD/build/MeetingAnalyzerE2E.app/Contents/MacOS/MeetingAnalyzer" [--artifacts DIR]
// 終了コード: 1 = fail あり、77 = blocked あり（fail がなければ）、0 = 全 pass
//
// 観測するもの: 実行ファイルの CLI（終了コード・標準出力・標準エラー）、本物の音声（`say` で作った日本語）を本物のオンデバイス認識に通した結果、
// エージェント側の窓口（`meeting-analyzer mcp`。MCP の JSON-RPC を、このハーネスが話す）が受け取る出来事、書き出された記録ファイル、
// メニューバーのアプリの起動・窓口（Unix ドメインソケット）・終了。
// 観測しないもの: マイク・システム音声の実取り込み、画面の取り込み、権限の許可。これらは人間の確認（docs/verification.md）。
import AppKit
import Foundation

// ---------- 引数 ----------
let argv = CommandLine.arguments
guard argv.count >= 2 else { FileHandle.standardError.write(Data("usage: native-e2e.swift <executable> [--artifacts DIR]\n".utf8)); exit(2) }
let exe = argv[1]
var artifactsRoot = FileManager.default.currentDirectoryPath + "/build/native-e2e"
if let i = argv.firstIndex(of: "--artifacts"), i + 1 < argv.count { artifactsRoot = argv[i + 1] }

// ---------- 結果 ----------
enum Verdict: String { case pass, fail, blocked }
var results: [(id: String, verdict: Verdict, detail: String)] = []
func record(_ id: String, _ verdict: Verdict, _ detail: String) {
    results.append((id, verdict, detail))
    print("[\(verdict.rawValue)] \(id): \(detail)")
    fflush(stdout)
}
/// 観測した値が期待と違えば fail。`ok` が真なら、何も記録しない（呼び出し側が最後に pass を記録する）。
var failures: [String] = []
func check(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append(message()) } }
func conclude(_ id: String, pass detail: String) {
    if failures.isEmpty { record(id, .pass, detail) } else { record(id, .fail, failures.joined(separator: " / ")) }
    failures = []
}

// ---------- 実行の補助 ----------
struct Ran { var status: Int32; var out: String; var err: String; var timedOut: Bool }
func run(_ path: String, _ args: [String], env: [String: String] = [:], timeout: Double = 60) -> Ran {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    var outData = Data(), errData = Data()
    let group = DispatchGroup()
    group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    do { try process.run() } catch { return Ran(status: -1, out: "", err: "launch failed: \(error)", timedOut: false) }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    var timedOut = false
    if process.isRunning { timedOut = true; process.terminate(); Thread.sleep(forTimeInterval: 0.3); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    process.waitUntilExit()
    group.wait()
    return Ran(status: process.terminationStatus, out: String(decoding: outData, as: UTF8.self), err: String(decoding: errData, as: UTF8.self), timedOut: timedOut)
}
func json(_ text: String) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))) as? [String: Any] }
func lastLine(_ text: String) -> String { text.split(separator: "\n").last.map(String.init) ?? "" }

// ---------- 作業ディレクトリ ----------
let stamp = { () -> String in let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
let work = artifactsRoot + "/run-" + stamp
try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let dataDir = work + "/data"
try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
/// ソケットのパスは 103 バイトまで。作業ディレクトリは深いので、短い場所に作る（0700 のディレクトリの中）。
let socketDir = "/tmp/ma-e2e-" + String((0..<8).map { _ in "abcdef0123456789".randomElement()! })
try FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let socketPath = socketDir + "/hub.sock"
/// 自分のプリセット（SPEC §3.11）。検証用のデータの置き場所の `presets/` に置く（利用者のものには、触れない）。
let customPresetBody = "E2E のカスタムの指示：結論を先に、3 行で出す。"
try FileManager.default.createDirectory(atPath: dataDir + "/presets", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
try Data("---\nname: E2Eカスタム\ndescription: 検証用の自分のプリセット\n---\n\(customPresetBody)\n".utf8).write(to: URL(fileURLWithPath: dataDir + "/presets/e2e-custom.md"))
let env = ["MEETING_ANALYZER_DATA_DIR": dataDir, "MEETING_ANALYZER_SOCKET": socketPath]
print("meeting-analyzer native E2E  executable=\(exe)  artifacts=\(work)")

guard FileManager.default.isExecutableFile(atPath: exe) else { record("E0", .blocked, "実行ファイルが見つからない: \(exe)（先に just build）"); exit(77) }

// ---------- Z: 起動せずに答える CLI ----------
do {
    let r = run(exe, ["--version"], env: env, timeout: 10)
    check(r.status == 0, "終了コード \(r.status)")
    check(r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "meeting-analyzer 0.1.10", "出力: \(r.out)")
    conclude("Z1", pass: "--version が版を出して 0 で終わる")
}
do {
    let r = run(exe, ["bogus"], env: env, timeout: 10)
    check(r.status == 1, "終了コード \(r.status)")
    check(json(lastLine(r.err))?["code"] as? String == "usage", "標準エラー: \(r.err)")
    conclude("Z2", pass: "知らないコマンドは、使い方の誤り（終了コード 1）を、標準エラーの JSON で返す")
}
do {
    let r = run(exe, ["replay", "/nonexistent/x.aiff"], env: env, timeout: 10)
    check(r.status == 2, "終了コード \(r.status)（読めない音声は 2）")
    conclude("Z3", pass: "読めない音声ファイルは、入力の失敗（終了コード 2）")
}
do {
    let r = run(exe, ["presets"], env: env, timeout: 10)
    check(r.status == 0, "終了コード \(r.status): \(r.err)")
    let rows = r.out.split(separator: "\n").compactMap { json(String($0)) }
    let ids = rows.compactMap { $0["id"] as? String }
    check(ids.first == "standard", "既定が先頭でない: \(ids)")
    check(Set(ids) == ["standard", "minutes", "tech-review", "learning", "video", "negotiation", "e2e-custom"], "プリセットの一覧が想定と違う: \(ids)")
    check(rows.first { $0["id"] as? String == "e2e-custom" }?["source"] as? String == "user", "自分のプリセットが user でない")
    check(rows.first { $0["id"] as? String == "minutes" }?["source"] as? String == "builtin", "同梱のプリセットが builtin でない")
    let bad = run(exe, ["replay", exe, "--preset", "nope"], env: env, timeout: 10)
    check(bad.status == 2 && lastLine(bad.err).contains("プリセットが見つかりません"), "無い ID の扱いが想定と違う: \(bad.status) \(bad.err)")
    conclude("Z4", pass: "presets が、同梱 6 件と自分のプリセットを、既定を先頭に一覧にする。無い ID の replay は、入力の失敗（終了コード 2）")
}

// ---------- 音声認識の前提 ----------
var asrReady = false
var asrReason = ""
do {
    let r = run(exe, ["doctor"], env: env, timeout: 30)
    let d = json(lastLine(r.out))
    asrReady = r.status == 0 && d?["supported"] as? Bool == true && d?["installed"] as? Bool == true
    if asrReady { record("D1", .pass, "ja_JP のオンデバイス認識が、この Mac で使える（doctor）") }
    else { asrReason = "ja_JP のオンデバイス認識を使えない: \(r.out) \(r.err)"; record("D1", .blocked, asrReason) }
}

// 日本語の音声（`say`）。声が無い・生成に失敗したら、認識のケースは blocked。
let sample = work + "/sample.aiff"
let phrase = "来週のリリースの件ですが、テスト環境はいつ使えるでしょうか。"
var sampleReady = false
if asrReady {
    let r = run("/usr/bin/say", ["-v", "Kyoko", "-o", sample, phrase], timeout: 60)
    sampleReady = r.status == 0 && FileManager.default.fileExists(atPath: sample)
    if !sampleReady { record("D2", .blocked, "日本語の声（Kyoko）で音声を作れない: \(r.err)") } else { record("D2", .pass, "検証用の日本語音声を作った（\(phrase)）") }
}

// ---------- 子プロセス（待たずに起動する）と、MCP のクライアント ----------
final class Child {
    let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let lock = NSLock()
    private var lines: [String] = []
    private var errText = ""
    private var buffer = Data()

    init?(_ path: String, _ args: [String], env: [String: String]) {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            lock.lock(); buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            lock.unlock()
        }
        stderr.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            lock.lock(); errText += String(decoding: data, as: UTF8.self); lock.unlock()
        }
        do { try process.run() } catch { return nil }
    }

    func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        try? stdin.fileHandleForWriting.write(contentsOf: data)
    }

    func closeInput() { try? stdin.fileHandleForWriting.close() }

    /// 受け取った行（JSON）をすべて。
    var messages: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return lines.compactMap { json($0) } }
    var outLines: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    var errors: String { lock.lock(); defer { lock.unlock() }; return errText }

    func waitForMessage(timeout: Double, _ match: ([String: Any]) -> Bool) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = messages.first(where: match) { return hit }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    func waitForExit(timeout: Double) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        return process.isRunning ? nil : process.terminationStatus
    }

    func stop() {
        closeInput()
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.3); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        process.waitUntilExit()
    }
}

/// `meeting-analyzer mcp` へ、MCP のハンドシェイクと get_events を話す。
final class McpClient {
    let child: Child
    private var nextId = 1
    init?(_ exe: String, channel: Bool = false, env: [String: String]) {
        guard let child = Child(exe, channel ? ["mcp", "--channel"] : ["mcp"], env: env) else { return nil }
        self.child = child
    }

    func request(_ method: String, _ params: [String: Any] = [:], timeout: Double = 10) -> [String: Any]? {
        let id = nextId; nextId += 1
        child.send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return child.waitForMessage(timeout: timeout) { $0["id"] as? Int == id }
    }

    func initialize() -> [String: Any]? {
        let reply = request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "native-e2e", "version": "1"]])
        child.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        return reply
    }

    /// get_events の結果（`connected`・`cursor`・`events`）。
    func getEvents(after: Int? = nil) -> [String: Any]? {
        var arguments: [String: Any] = [:]
        if let after { arguments["after"] = after }
        guard let reply = request("tools/call", ["name": "get_events", "arguments": arguments]),
              let text = ((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String else { return nil }
        return json(text)
    }

    func stop() { child.stop() }
}

/// ソケットの権限（ファイル）。
func mode(_ path: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? Int) ?? -1 }

/// 窓口（ハブ）から、終了の出来事まで、get_events で読み集める。
func collectEvents(_ mcp: McpClient, timeout: Double) -> [[String: Any]] {
    var after = 0
    var all: [[String: Any]] = []
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let result = mcp.getEvents(after: after), let events = result["events"] as? [[String: Any]] {
            all += events
            after = result["cursor"] as? Int ?? after
            if events.contains(where: { ($0["event"] as? [String: Any])?["kind"] as? String == "ended" }) { return all }
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
    return all
}

// ---------- R: 音声ファイル → 文字起こし → 窓口 → エージェント側の MCP ----------
func replayCase(_ id: String, speaker: String, expectedName: String, channel: Bool = false, preset: String? = nil, expectedPreset: (id: String, name: String) = ("standard", "標準")) {
    guard asrReady, sampleReady else { record(id, .blocked, asrReady ? "検証用の音声がない" : asrReason); return }
    // エージェント側（mcp）を先に起動する。窓口が開くまでは、つなぎ直しながら待つ。
    guard let mcp = McpClient(exe, channel: channel, env: env) else { record(id, .blocked, "mcp を起動できない"); return }
    defer { mcp.stop() }
    let handshake = mcp.initialize()
    check(handshake != nil, "initialize に返事がない")
    let result = handshake?["result"] as? [String: Any]
    let capabilities = result?["capabilities"] as? [String: Any]
    check(capabilities?["tools"] != nil, "tools を宣言していない")
    check((capabilities?["experimental"] != nil) == channel, "チャンネルの宣言が想定と違う（--channel=\(channel)）")
    check((result?["instructions"] as? String)?.isEmpty == false, "instructions が空")

    // 再生：窓口を開き、エージェントがつながるのを待ってから、再生を始める。終わっても、窓口を少しの間、開けておく。
    guard let replay = Child(exe, ["replay", sample, "--speaker", speaker, "--title", "e2e-\(id)", "--wait", "30", "--hold", "6"] + (preset.map { ["--preset", $0] } ?? []), env: env) else {
        record(id, .blocked, "replay を起動できない"); return
    }
    defer { replay.stop() }
    var pushed: [[String: Any]] = []
    let events: [[String: Any]]
    if channel {
        // 押し込みの通知が、終了の出来事まで届くのを待つ。
        let ended = mcp.child.waitForMessage(timeout: 90) { (($0["params"] as? [String: Any])?["meta"] as? [String: Any])?["kind"] as? String == "ended" }
        check(ended != nil, "終了の出来事が、押し込みで届かない")
        pushed = mcp.child.messages.filter { $0["method"] as? String == "notifications/claude/channel" }
        events = collectEvents(mcp, timeout: 10)
    } else {
        events = collectEvents(mcp, timeout: 90)
    }
    let code = replay.waitForExit(timeout: 30)
    check(code == 0, "replay の終了コード \(String(describing: code)): \(replay.errors)")
    check(mode(socketPath) == 0o600 || !FileManager.default.fileExists(atPath: socketPath), "ソケットの権限が 0600 でない")

    let bodies = events.compactMap { $0["event"] as? [String: Any] }
    let kinds = bodies.compactMap { $0["kind"] as? String }
    check(kinds.first == "started", "最初が started でない: \(kinds)")
    check(kinds.last == "ended", "最後が ended でない: \(kinds)")
    check(kinds.filter { $0 == "ended" }.count == 1, "ended が 1 件でない")
    check(kinds.contains("captions"), "captions が 1 件もない")
    check(events.compactMap { $0["id"] as? Int } == Array(1...max(1, events.count)).prefix(events.count).map { $0 }, "通し番号が 1 から連続していない")
    check(Set(bodies.compactMap { $0["sessionId"] as? String }).count == 1, "sessionId が 1 つでない")
    let batches = bodies.filter { $0["kind"] as? String == "captions" }
    check(batches.map { $0["sequence"] as? Int ?? -1 } == Array(1...max(1, batches.count)).prefix(batches.count).map { $0 }, "sequence が 1 から連続していない")
    let updates = batches.flatMap { ($0["updates"] as? [[String: Any]]) ?? [] }
    let latest = Dictionary(updates.map { ($0["id"] as? String ?? "", $0["text"] as? String ?? "") }, uniquingKeysWith: { $1 }).values.joined()
    check(updates.allSatisfy { $0["speaker"] as? String == expectedName }, "speaker が \(expectedName) でない")
    check(updates.allSatisfy { $0["source"] as? String == speaker }, "source が \(speaker) でない")
    check(latest.contains("リリース"), "認識結果に「リリース」がない: \(latest)")
    check(latest.contains("テスト環境"), "認識結果に「テスト環境」がない: \(latest)")
    check((bodies.first?["sources"] as? [String]) == [speaker], "started の sources が想定と違う")
    let carried = bodies.first?["preset"] as? [String: Any]
    check(carried?["id"] as? String == expectedPreset.id && carried?["name"] as? String == expectedPreset.name, "started の preset が想定と違う: \(String(describing: carried))")
    check((carried?["instructions"] as? String ?? "").count > 20, "preset の instructions が空に近い")
    if expectedPreset.id == "e2e-custom" { check(carried?["instructions"] as? String == customPresetBody, "自分のプリセットの本文が、そのまま届いていない") }

    if let end = bodies.last(where: { $0["kind"] as? String == "ended" }) {
        check(end["reason"] as? String == "user", "reason が user でない")
        check(end["batches"] as? Int == batches.count, "batches \(String(describing: end["batches"])) が出した数 \(batches.count) と違う")
        check((end["utterances"] as? Int ?? 0) >= 1, "utterances が 0")
        check((end["durationSeconds"] as? Int ?? 0) >= 1, "durationSeconds が 0")
        if let path = end["transcriptPath"] as? String {
            check(path.hasPrefix(dataDir), "記録が dataDir の外: \(path)")
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            check(text.contains("\(expectedName):") && text.contains("リリース"), "記録の本文が想定と違う")
            check(mode(path) == 0o600, "記録の権限が 0600 でない: \(mode(path))")
            check(mode(URL(fileURLWithPath: path).deletingLastPathComponent().path) == 0o700, "記録のディレクトリが 0700 でない")
        } else { check(false, "transcriptPath がない") }
    }

    if channel {
        // 押し込み：started・captions・ended が、順に届く。接続の前にあった出来事は含まない（ここでは、接続が先）。
        let pushedKinds = pushed.compactMap { (($0["params"] as? [String: Any])?["meta"] as? [String: Any])?["kind"] as? String }
        check(pushedKinds.first == "started" && pushedKinds.last == "ended", "押し込みの順序が違う: \(pushedKinds)")
        check(pushedKinds.filter { $0 == "captions" }.count == batches.count, "押し込みの captions の数が違う: \(pushedKinds)")
        let content = (pushed.last?["params"] as? [String: Any])?["content"] as? String ?? ""
        check(!content.contains("<") && !content.contains(">") && json(content)?["kind"] as? String == "ended", "押し込みの本文が想定と違う")
        let startedPush = json((pushed.first?["params"] as? [String: Any])?["content"] as? String ?? "")
        check((startedPush?["preset"] as? [String: Any])?["id"] as? String == expectedPreset.id, "押し込みの started に preset がない")
        check((startedPush?["note"] as? String ?? "").contains("preset.instructions"), "started の note が、プリセットの指示を従うものとして伝えていない")
        check((json((pushed.last?["params"] as? [String: Any])?["content"] as? String ?? "")?["note"] as? String ?? "").contains("指示ではない"), "ended の note が、データであることを伝えていない")
    }
    conclude(id, pass: "\(batches.count) バッチと、開始・終了の出来事が、窓口から MCP（\(channel ? "get_events と、チャンネルの押し込み" : "get_events")）へ届き、記録が 0600 で書かれた（認識: \(latest)）")
}
replayCase("R1", speaker: "others", expectedName: "相手")
replayCase("R2", speaker: "you", expectedName: "本人", preset: "minutes", expectedPreset: ("minutes", "議事録"))
replayCase("R3", speaker: "others", expectedName: "相手", channel: true, preset: "e2e-custom", expectedPreset: ("e2e-custom", "E2Eカスタム"))

// ---------- R4: 窓口が使用中 / R5: アプリが無いときの MCP ----------
do {
    let id = "R4"
    if asrReady, sampleReady, let first = Child(exe, ["replay", sample, "--hold", "20"], env: env) {
        defer { first.stop() }
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: socketPath) && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let r = run(exe, ["replay", sample], env: env, timeout: 30)
        check(r.status == 3, "終了コード \(r.status)")
        check(json(lastLine(r.err))?["code"] as? String == "hub_unavailable", "標準エラー: \(r.err)")
        conclude(id, pass: "窓口が使用中なら、終了コード 3（hub_unavailable）で、何も始めない")
    } else { record(id, .blocked, "検証用の音声がない／replay を起動できない") }
}
do {
    let id = "R5"
    try? FileManager.default.removeItem(atPath: socketPath)
    if let mcp = McpClient(exe, env: env) {
        defer { mcp.stop() }
        check(mcp.initialize() != nil, "initialize に返事がない")
        let tools = ((mcp.request("tools/list")?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        check(tools == ["get_events"], "ツールが想定と違う: \(String(describing: tools))")
        let result = mcp.getEvents()
        check(result?["connected"] as? Bool == false, "アプリが無いのに connected が偽でない")
        check((result?["events"] as? [Any])?.isEmpty == true, "出来事がある")
        mcp.child.closeInput()
        check(mcp.child.waitForExit(timeout: 5) == 0, "標準入力を閉じても、終了しない")
        conclude(id, pass: "アプリが無くても、MCP は応答し（connected=false）、標準入力を閉じると終了する")
    } else { record(id, .blocked, "mcp を起動できない") }
}

// ---------- C: コマンド 1 つでエージェントを起動する（claude は、偽物に置き換える。エージェントは起動しない） ----------
do {
    let id = "C1"
    let stubDir = work + "/stub"
    try FileManager.default.createDirectory(atPath: stubDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let argsFile = work + "/claude-args.txt"
    let stub = stubDir + "/claude"
    // 受け取った引数を 1 行ずつ書き出すだけの偽の claude。
    try Data("#!/bin/bash\nprintf '%s\\n' \"$@\" > '\(argsFile)'\nexit 7\n".utf8).write(to: URL(fileURLWithPath: stub))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub)
    let r = run(exe, ["claude", "会議を始めます", "--resume"], env: env.merging(["PATH": stubDir + ":/usr/bin:/bin"]) { $1 }, timeout: 30)
    let args = ((try? String(contentsOfFile: argsFile, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLast()
    check(r.status == 7, "終了コード \(r.status)（偽の claude の 7 に置き換わっているはず）")
    check(Array(args.prefix(2)) == ["会議を始めます", "--resume"], "利用者の引数が先頭にない: \(Array(args))")
    check(args.suffix(2) == ["--dangerously-load-development-channels", "server:meeting-analyzer-channel"], "チャンネルの指定が最後にない")
    if let i = args.firstIndex(of: "--append-system-prompt-file"), i + 1 < args.endIndex {
        let skill = (try? String(contentsOfFile: String(args[i + 1]), encoding: .utf8)) ?? ""
        check(skill.contains("meeting-analyzer") && skill.contains("本人"), "同梱の skill を読めない: \(args[i + 1])")
    } else { check(false, "--append-system-prompt-file（同梱の skill）が渡されていない") }
    if let i = args.firstIndex(of: "--mcp-config"), i + 1 < args.endIndex, let config = json(String(args[i + 1])),
       let server = (config["mcpServers"] as? [String: Any])?["meeting-analyzer-channel"] as? [String: Any] {
        check((server["command"] as? String).map { FileManager.default.isExecutableFile(atPath: $0) } == true, "MCP のコマンドが実行ファイルでない")
        check(server["args"] as? [String] == ["mcp", "--channel"], "MCP の引数が違う")
        check((server["env"] as? [String: String])?["MEETING_ANALYZER_SOCKET"] == socketPath, "窓口の場所を、mcp へ渡していない")
    } else { check(false, "--mcp-config の JSON を読めない") }
    // claude が無い PATH：エージェントを起動できない失敗（終了コード 5）。
    let missing = run(exe, ["claude"], env: env.merging(["PATH": "/usr/bin:/bin"]) { $1 }, timeout: 30)
    check(missing.status == 5 && json(lastLine(missing.err))?["code"] as? String == "agent_unavailable", "claude が無いときの失敗が違う: \(missing.status) \(missing.err)")
    conclude(id, pass: "claude は、利用者の引数 → MCP の設定（--channel・窓口の場所）→ チャンネルの指定の順で渡して置き換わり、無ければ終了コード 5")
} catch { record("C1", .blocked, "偽の claude を用意できない: \(error)") }

// ---------- C2: pi・omp・opencode を、コマンド 1 つで起動する（設定へ MCP サーバーを自動で登録。エージェントは、偽物に置き換える） ----------
do {
    let id = "C2"
    let stubDir = work + "/stub-agents"
    try FileManager.default.createDirectory(atPath: stubDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for name in ["pi", "omp", "opencode"] {
        let argsFile = work + "/\(name)-args.txt"
        let stub = stubDir + "/" + name
        try Data("#!/bin/bash\nprintf '%s\\n' \"$@\" > '\(argsFile)'\nprintf '%s' \"$OPENCODE_CONFIG_CONTENT\" > '\(argsFile).env'\nexit 7\n".utf8).write(to: URL(fileURLWithPath: stub))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub)
    }
    let path = stubDir + ":/usr/bin:/bin"
    // 各エージェントの設定の置き場所を、検証用に向ける（利用者の設定には、触れない）。
    let setups: [(name: String, env: [String: String], file: String, container: String)] = [
        ("pi", ["PI_CODING_AGENT_DIR": work + "/pi-cfg"], work + "/pi-cfg/mcp.json", "mcpServers"),
        ("omp", ["PI_CODING_AGENT_DIR": work + "/omp-cfg"], work + "/omp-cfg/mcp.json", "mcpServers"),
        ("opencode", ["XDG_CONFIG_HOME": work + "/xdg", "HOME": work + "/oc-home"], work + "/xdg/opencode/opencode.json", "mcp"),
    ]
    for setup in setups {
        let environment = env.merging(setup.env) { $1 }.merging(["PATH": path]) { $1 }
        let r1 = run(exe, [setup.name, "hello"], env: environment, timeout: 30)
        check(r1.status == 7, "\(setup.name): 終了コード \(r1.status)（偽のエージェントの 7 に置き換わるはず）: \(r1.err)")
        let args = ((try? String(contentsOfFile: work + "/\(setup.name)-args.txt", encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLast()
        check(args.first == "hello", "\(setup.name): 利用者の引数が先頭にない: \(Array(args))")
        check(args.contains("--standalone") == (setup.name == "opencode"), "\(setup.name): --standalone は、opencode だけ: \(Array(args))")
        let configContent = (try? String(contentsOfFile: work + "/\(setup.name)-args.txt.env", encoding: .utf8)) ?? ""
        if setup.name == "opencode" {
            let config = json(configContent)
            let plugins = config?["plugin"] as? [String] ?? []
            check(plugins.count == 1 && FileManager.default.isReadableFile(atPath: plugins[0] + "/server.js") && FileManager.default.isReadableFile(atPath: plugins[0] + "/package.json"), "opencode: 字幕を押し込むプラグイン（ディレクトリ）が、設定に載っていない: \(configContent)")
            check((config?["instructions"] as? [String])?.first.map { FileManager.default.isReadableFile(atPath: $0) } == true, "opencode: skill が、設定に載っていない: \(configContent)")
        } else {
            check(configContent.isEmpty, "\(setup.name): opencode 以外に、OPENCODE_CONFIG_CONTENT を渡してはいけない")
        }
        let skillExpected = setup.name == "pi" || setup.name == "omp"
        check((args.contains("--append-system-prompt")) == skillExpected, "\(setup.name): skill の引き渡しが想定と違う: \(Array(args))")
        if skillExpected {
            let extensionFile = args.firstIndex(of: "-e").flatMap { $0 + 1 < args.endIndex ? String(args[$0 + 1]) : nil }
            check(extensionFile.map { FileManager.default.isReadableFile(atPath: $0) && $0.hasSuffix("meeting-analyzer-pi.js") } == true, "\(setup.name): 字幕を押し込む拡張（-e）が渡されていない: \(Array(args))")
        } else {
            check(!args.contains("-e"), "\(setup.name): 拡張は、pi・omp だけ")
        }
        let first = (try? Data(contentsOf: URL(fileURLWithPath: setup.file))) ?? Data()
        let object = json(String(decoding: first, as: UTF8.self))
        let entry = ((object?[setup.container] as? [String: Any])?["meeting-analyzer"]) as? [String: Any]
        let command = setup.name == "opencode" ? (entry?["command"] as? [String])?.first : entry?["command"] as? String
        check(command.map { FileManager.default.isExecutableFile(atPath: $0) } == true, "\(setup.name): 設定に、MCP サーバー（実行ファイル）が登録されていない: \(setup.file)")
        check(r1.err.contains("登録しました"), "\(setup.name): 登録したことを伝えていない: \(r1.err)")
        // 2 回目：登録済みなので、何も書かない（内容が同じ。登録のメッセージも出ない）。
        let r2 = run(exe, [setup.name], env: environment, timeout: 30)
        check((try? Data(contentsOf: URL(fileURLWithPath: setup.file))) == first, "\(setup.name): 登録済みなのに、設定を書き換えた")
        check(!r2.err.contains("MCP サーバーを登録") && !r2.err.contains("MCP サーバーの登録"), "\(setup.name): 2 回目も、登録・更新のメッセージが出た: \(r2.err)")
    }
    conclude(id, pass: "pi・omp・opencode は、設定へ 1 件だけ登録し（2 回目は何も書かない）、利用者の引数 →（pi・omp は、字幕を押し込む拡張と skill。opencode は、`--standalone` と、プラグイン・skill を載せた設定）の順で、エージェントに置き換わる")
} catch { record("C2", .blocked, "偽のエージェントを用意できない: \(error)") }

// ---------- A: メニューバーのアプリとして起動・終了 ----------
do {
    let id = "A1"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe)
    process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let pid = process.processIdentifier
        let deadline = Date().addingTimeInterval(6)
        var app: NSRunningApplication?
        while Date() < deadline, app == nil { app = NSRunningApplication(processIdentifier: pid); Thread.sleep(forTimeInterval: 0.1) }
        Thread.sleep(forTimeInterval: 1.5)
        check(process.isRunning, "起動して 1.5 秒で終了した")
        // アクセサリ（Dock に出ない）になるのは、アプリバンドル（LSUIElement）か、コード側の指定のとき。どちらでも accessory であるべき。
        if let app { check(app.activationPolicy == .accessory, "activationPolicy が accessory でない: \(app.activationPolicy.rawValue)") }
        else { check(false, "NSRunningApplication を取得できない") }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        check(windows.isEmpty, "通常のウィンドウが \(windows.count) 個ある（メニューバーだけのはず）")
        // 窓口：ソケットが 0600 で開き、エージェント側の MCP がつながる。
        check(mode(socketPath) == 0o600, "ソケットの権限が 0600 でない: \(mode(socketPath))")
        if let mcp = McpClient(exe, env: env) {
            _ = mcp.initialize()
            var connected = false
            let until = Date().addingTimeInterval(8)
            while !connected && Date() < until { connected = mcp.getEvents()?["connected"] as? Bool == true; if !connected { Thread.sleep(forTimeInterval: 0.3) } }
            check(connected, "MCP が、実行中のアプリの窓口へつながらない")
            mcp.stop()
        } else { check(false, "mcp を起動できない") }
        process.terminate()
        let end = Date().addingTimeInterval(5)
        while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        check(!process.isRunning, "SIGTERM で終了しない")
        if process.isRunning { kill(pid, SIGKILL) }
        check(!FileManager.default.fileExists(atPath: socketPath), "終了したのに、ソケットが残っている")
        conclude(id, pass: "引数なしで起動すると、Dock にもウィンドウにも出ずに常駐し、窓口（0600）を開け、MCP がつながり、SIGTERM で終了して窓口を閉じる")
    } catch { record(id, .blocked, "起動できない: \(error)") }
}

// ---------- 報告 ----------
let counts = Dictionary(grouping: results, by: { $0.verdict }).mapValues(\.count)
let summary = "pass=\(counts[.pass] ?? 0) fail=\(counts[.fail] ?? 0) blocked=\(counts[.blocked] ?? 0)"
let report: [String: Any] = [
    "executable": exe, "date": ISO8601DateFormatter().string(from: Date()), "summary": summary,
    "cases": results.map { ["id": $0.id, "verdict": $0.verdict.rawValue, "detail": $0.detail] },
]
if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
    let path = work + "/report.json"
    try? data.write(to: URL(fileURLWithPath: path))
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}
try? FileManager.default.removeItem(atPath: socketDir)
print("今回の report: \(summary)  (\(work)/report.json)")
exit((counts[.fail] ?? 0) > 0 ? 1 : ((counts[.blocked] ?? 0) > 0 ? 77 : 0))
