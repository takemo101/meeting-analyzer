#!/usr/bin/swift
// meeting-analyzer native E2E（verifying-macos-apps 準拠）。自分で起動したプロセスだけを操作する。
// 使い方（リポジトリのルートで）:
//   /usr/bin/swift scripts/native-e2e.swift "$PWD/build/MeetingAnalyzerE2E.app/Contents/MacOS/MeetingAnalyzer" [--artifacts DIR]
// 終了コード: 1 = fail あり、77 = blocked あり（fail がなければ）、0 = 全 pass
//
// 観測するもの: 実行ファイルの CLI（終了コード・標準出力・標準エラー）、本物の音声（`say` で作った日本語）を本物のオンデバイス認識に通した結果、
// 偽のブリッジ（scripts/e2e-bridge.mjs）が受け取った HTTP 要求、書き出された記録ファイル、メニューバーのアプリの起動と終了。
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
let dataDir = work + "/data", tokenDir = work + "/token"
for dir in [dataDir, tokenDir] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
let token = (0..<43).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }.map(String.init).joined()
try Data(token.utf8).write(to: URL(fileURLWithPath: tokenDir + "/token"))
let env = ["MEETING_ANALYZER_DATA_DIR": dataDir, "LIVE_SUPPORT_RUNTIME_DIR": tokenDir]
print("meeting-analyzer native E2E  executable=\(exe)  artifacts=\(work)")

guard FileManager.default.isExecutableFile(atPath: exe) else { record("E0", .blocked, "実行ファイルが見つからない: \(exe)（先に just build）"); exit(77) }

// ---------- Z: 起動せずに答える CLI ----------
do {
    let r = run(exe, ["--version"], env: env, timeout: 10)
    check(r.status == 0, "終了コード \(r.status)")
    check(r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "meeting-analyzer 0.1.0", "出力: \(r.out)")
    conclude("Z1", pass: "--version が版を出して 0 で終わる")
}
do {
    let r = run(exe, ["bogus"], env: env, timeout: 10)
    check(r.status == 1, "終了コード \(r.status)")
    check(json(lastLine(r.err))?["code"] as? String == "usage", "標準エラー: \(r.err)")
    conclude("Z2", pass: "知らないコマンドは、使い方の誤り（終了コード 1）を、標準エラーの JSON で返す")
}
do {
    let r = run(exe, ["replay", "/nonexistent/x.aiff", "--bridge", "http://127.0.0.1:1"], env: env, timeout: 10)
    check(r.status == 2, "終了コード \(r.status)（読めない音声は 2）")
    conclude("Z3", pass: "読めない音声ファイルは、入力の失敗（終了コード 2）")
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

// ---------- 偽のブリッジ ----------
final class Bridge {
    let process = Process()
    let log: String
    var port = 0
    init?(token: String, log: String, mode: String = "ok", script: String) {
        self.log = log
        FileManager.default.createFile(atPath: log, contents: nil)
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
                ?? Bridge.which("node") else { return nil }
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script, "--token", token, "--log", log, "--mode", mode]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(10)
        var buffer = Data()
        while Date() < deadline {
            let chunk = out.fileHandleForReading.availableData
            buffer.append(chunk)
            if let line = String(data: buffer, encoding: .utf8)?.split(separator: "\n").first(where: { $0.hasPrefix("PORT ") }), let p = Int(line.dropFirst(5)) { port = p; break }
            if chunk.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        }
        if port == 0 { stop(); return nil }
    }
    static func which(_ name: String) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/which"); p.arguments = [name]
        let o = Pipe(); p.standardOutput = o; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        let s = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
    var url: String { "http://127.0.0.1:\(port)" }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    func requests() -> [[String: Any]] {
        (try? String(contentsOfFile: log, encoding: .utf8))?.split(separator: "\n").compactMap { json(String($0)) } ?? []
    }
}
let scriptPath = FileManager.default.currentDirectoryPath + "/scripts/e2e-bridge.mjs"

// ---------- R: 音声ファイル → 文字起こし → バッチ → 終了の合図 ----------
func replayCase(_ id: String, speaker: String, expectedName: String) {
    guard asrReady, sampleReady else { record(id, .blocked, asrReady ? "検証用の音声がない" : asrReason); return }
    guard let bridge = Bridge(token: token, log: work + "/\(id)-bridge.jsonl", script: scriptPath) else { record(id, .blocked, "偽のブリッジ（node scripts/e2e-bridge.mjs）を起動できない"); return }
    defer { bridge.stop() }
    let r = run(exe, ["replay", sample, "--bridge", bridge.url, "--speaker", speaker, "--meeting", "e2e-\(id)", "--token-dir", tokenDir], env: env, timeout: 120)
    check(!r.timedOut, "タイムアウト")
    check(r.status == 0, "終了コード \(r.status): \(r.err)")
    let log = bridge.requests()
    check(log.first?["method"] as? String == "GET" && log.first?["path"] as? String == "/health", "最初の要求が /health でない")
    check(log.allSatisfy { $0["authorized"] as? Bool == true }, "認証されていない要求がある")
    check(log.allSatisfy { $0["host"] as? String == "127.0.0.1:\(bridge.port)" }, "Host が想定と違う")
    let captions = log.filter { $0["path"] as? String == "/captions" }
    let ends = log.filter { $0["path"] as? String == "/end" }
    check(!captions.isEmpty, "/captions が 1 件もない")
    check(ends.count == 1, "/end が \(ends.count) 件（1 件であるべき）")
    check(log.last?["path"] as? String == "/end", "終了の合図が最後でない")
    check(log.allSatisfy { ($0["status"] as? Int ?? 0) / 100 == 2 }, "2xx でない応答がある")

    let batches = captions.compactMap { json($0["body"] as? String ?? "") }
    check(batches.map { $0["sequence"] as? Int ?? -1 } == Array(1...max(1, batches.count)).prefix(batches.count).map { $0 }, "sequence が 1 から連続していない")
    let sessionIds = Set(batches.compactMap { $0["sessionId"] as? String } + ends.compactMap { json($0["body"] as? String ?? "")?["sessionId"] as? String })
    check(sessionIds.count == 1, "sessionId が 1 つでない: \(sessionIds)")
    check(batches.allSatisfy { $0["platform"] as? String == "Mac" && $0["meetingId"] as? String == "e2e-\(id)" }, "platform / meetingId が違う")
    let updates = batches.flatMap { ($0["updates"] as? [[String: Any]]) ?? [] }
    let latest = Dictionary(updates.map { ($0["messageId"] as? String ?? "", $0["transcript"] as? String ?? "") }, uniquingKeysWith: { $1 }).values.joined()
    check(updates.allSatisfy { $0["speakerName"] as? String == expectedName }, "speakerName が \(expectedName) でない")
    check(latest.contains("リリース"), "認識結果に「リリース」がない: \(latest)")
    check(latest.contains("テスト環境"), "認識結果に「テスト環境」がない: \(latest)")

    if let end = ends.first.flatMap({ json($0["body"] as? String ?? "") }) {
        check(end["reason"] as? String == "user", "reason が user でない")
        check(end["batches"] as? Int == batches.count, "batches \(String(describing: end["batches"])) が送った数 \(batches.count) と違う")
        check((end["utterances"] as? Int ?? 0) >= 1, "utterances が 0")
        check((end["durationSeconds"] as? Int ?? 0) >= 1, "durationSeconds が 0")
        if let path = end["transcriptPath"] as? String {
            check(path.hasPrefix(dataDir), "記録が dataDir の外: \(path)")
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            check(text.contains("\(expectedName):") && text.contains("リリース"), "記録の本文が想定と違う")
            let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1
            check(mode == 0o600, "記録の権限が 0600 でない: \(String(describing: mode))")
        } else { check(false, "transcriptPath がない") }
    }
    conclude(id, pass: "\(batches.count) バッチと終了の合図が、認証つきでブリッジへ届き、記録が 0600 で書かれた（認識: \(latest)）")
}
replayCase("R1", speaker: "others", expectedName: "相手")
replayCase("R2", speaker: "you", expectedName: "あなた")

// ---------- R3 / R4: ブリッジの失敗 ----------
do {
    let id = "R3"
    if let bridge = Bridge(token: "x" + token, log: work + "/R3-bridge.jsonl", script: scriptPath) {
        defer { bridge.stop() }
        let r = run(exe, ["replay", sample, "--bridge", bridge.url, "--token-dir", tokenDir], env: env, timeout: 30)
        check(r.status == 3, "終了コード \(r.status)")
        check(json(lastLine(r.err))?["code"] as? String == "bridge_unauthorized", "標準エラー: \(r.err)")
        check(bridge.requests().allSatisfy { $0["path"] as? String == "/health" }, "認証に失敗したのに、/health 以外を送った")
        conclude(id, pass: "トークンが違うと、文字起こしを始める前に、終了コード 3（bridge_unauthorized）で止まる")
    } else { record(id, .blocked, "偽のブリッジを起動できない") }
}
do {
    let id = "R4"
    let r = run(exe, ["replay", sample, "--bridge", "http://127.0.0.1:9", "--token-dir", tokenDir], env: env, timeout: 30)
    check(r.status == 3, "終了コード \(r.status)")
    check(json(lastLine(r.err))?["code"] as? String == "bridge_unreachable", "標準エラー: \(r.err)")
    conclude(id, pass: "ブリッジが無いと、終了コード 3（bridge_unreachable）")
}
do {
    let id = "R5"
    let r = run(exe, ["replay", sample, "--bridge", "https://example.com", "--token-dir", tokenDir], env: env, timeout: 30)
    check(r.status == 3, "終了コード \(r.status)")
    check(json(lastLine(r.err))?["code"] as? String == "endpoint_invalid", "標準エラー: \(r.err)")
    conclude(id, pass: "ローカル以外の送り先は、通信する前に断る（endpoint_invalid）")
}

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
        process.terminate()
        let end = Date().addingTimeInterval(5)
        while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        check(!process.isRunning, "SIGTERM で終了しない")
        if process.isRunning { kill(pid, SIGKILL) }
        conclude(id, pass: "引数なしで起動すると、Dock にもウィンドウにも出ずに常駐し、SIGTERM で終了する")
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
print("今回の report: \(summary)  (\(work)/report.json)")
exit((counts[.fail] ?? 0) > 0 ? 1 : ((counts[.blocked] ?? 0) > 0 ? 77 : 0))
