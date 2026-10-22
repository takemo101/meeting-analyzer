import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import MeetingAnalyzerKit

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ma-report-" + UUID().uuidString, isDirectory: true)
}

private func permissions(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1
}

private func writeJPEG(_ name: String, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try #require(ImageTools.jpegData(of: makeImage(width: 1280, height: 720, gray: 90)))
    try data.write(to: directory.appendingPathComponent(name))
}

private func sampleData(lines: Int = 3, shots: [ReportData.Shot] = []) -> ReportData {
    ReportData(
        title: "相手 2026-10-22 15:30", startedAt: "2026-10-22 15:30", durationSeconds: 125,
        lines: (0..<lines).map { ReportData.Line(at: Double($0) * 10, speaker: $0 % 3 == 2 ? "本人" : "相手", text: "来週のリリースの件です。テスト環境はいつ使えますか。\($0)") },
        shots: shots
    )
}

@Suite("資料（PDF）: 描画・保存・サマリーの差し込み")
struct ReportTests {
    @Test("記録が PDF になる：表題・概要・各発話が、文字として入り、長ければ複数ページになる")
    func rendersTranscript() throws {
        let short = try #require(PDFReportRenderer.render(sampleData(), summary: nil, imageDirectory: tempDirectory()))
        let shortDocument = try #require(PDFDocument(data: short))
        #expect(shortDocument.pageCount == 1)
        let text = shortDocument.string ?? ""
        #expect(text.contains("来週のリリースの件です") && text.contains("[00:20]") && text.contains("本人") && text.contains("発話 3 件") && text.contains("長さ 02:05"))
        #expect(!text.contains("サマリー"), "サマリーが無ければ、見出しも出さない")

        let long = try #require(PDFReportRenderer.render(sampleData(lines: 400), summary: nil, imageDirectory: tempDirectory()))
        #expect(try #require(PDFDocument(data: long)).pageCount > 3, "400 行は、複数のページに流れる")
    }

    @Test("サマリーは、先頭の見出しの下に入り、Markdown の印（# ・- ・**）は、そのまま出ない")
    func rendersSummary() throws {
        let summary = "# 概要\n- 来週の**リリース**の相談\n1. 環境の確認\n> 注意：認識の誤りの可能性"
        let pdf = try #require(PDFReportRenderer.render(sampleData(), summary: summary, imageDirectory: tempDirectory()))
        let text = try #require(PDFDocument(data: pdf)?.string)
        #expect(text.contains("サマリー") && text.contains("概要") && text.contains("リリース") && text.contains("環境の確認") && text.contains("認識の誤りの可能性"))
        #expect(!text.contains("**") && !text.contains("# 概要"))
        #expect(try #require(text.range(of: "サマリー")).lowerBound < (try #require(text.range(of: "記録と画面")).lowerBound))
    }

    @Test("画面の画像は、撮った時刻の位置に、キャプションつきで入る。読めない画像は、その旨を示して、続ける")
    func embedsScreens() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeJPEG("shot-0001.jpg", in: directory.appendingPathComponent("screens"))
        let shots = [ReportData.Shot(at: 15, file: "screens/shot-0001.jpg"), ReportData.Shot(at: 25, file: "screens/missing.jpg")]
        let withShots = try #require(PDFReportRenderer.render(sampleData(shots: shots), summary: nil, imageDirectory: directory))
        let text = try #require(PDFDocument(data: withShots)?.string)
        #expect(text.contains("画面（00:15）") && text.contains("画面（00:25）：画像を読めませんでした") && text.contains("画面 2 枚"))
        let first = try #require(text.range(of: "[00:10]")), screen = try #require(text.range(of: "画面（00:15）")), second = try #require(text.range(of: "[00:20]"))
        #expect(first.lowerBound < screen.lowerBound && screen.lowerBound < second.lowerBound, "00:10 と 00:20 の発話の間に、00:15 の画面")
        let plain = try #require(PDFReportRenderer.render(sampleData(), summary: nil, imageDirectory: directory))
        #expect(withShots.count > plain.count + 5_000, "画像のデータが、PDF に埋め込まれている")
    }

    @Test("保存：元データと PDF を、利用者だけが読める権限で書く。サマリーを渡すと、同じデータから作り直せる。元データが無ければ、作り直せない")
    func buildAndRebuild() throws {
        let directory = tempDirectory().appendingPathComponent("sessions/abc", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().deletingLastPathComponent()) }
        let url = try ReportBuilder.write(sampleData(), summary: nil, in: directory).get()
        #expect(url.lastPathComponent == "report.pdf" && permissions(url) == 0o600 && permissions(directory.appendingPathComponent("report-data.json")) == 0o600 && permissions(directory) == 0o700)
        let first = PDFDocument(url: url)?.string ?? ""
        #expect(first.contains("来週のリリースの件です") && !first.contains("サマリー"), "\(first)")

        _ = try ReportBuilder.rebuild(summary: "**決定**：金曜に確認", in: directory).get()
        let rebuilt = PDFDocument(url: url)?.string ?? ""
        #expect(rebuilt.contains("サマリー") && rebuilt.contains("金曜に確認") && rebuilt.contains("来週のリリースの件です"), "サマリーが入り、記録も残る")

        #expect(ReportBuilder.rebuild(summary: "x", in: tempDirectory()) == .failure(.noData))
    }
}

@Suite("MCP save_report: エージェントのサマリーを、資料へ入れる")
struct SaveReportTests {
    private func rpc(_ id: Int, _ arguments: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": "save_report", "arguments": arguments]] as [String: Any])
    }

    private func ended(_ sessionId: String, report: String?) -> TranscriptEvent {
        .ended(sessionId: sessionId, title: "t", reason: "user", startedAt: "a", endedAt: "b", durationSeconds: 1, batches: 1, utterances: 1, transcriptPath: "/x/transcript.md", reportPath: report)
    }

    private func serve(_ events: [TranscriptEvent]) async -> (MCPServer, Wire) {
        let wire = Wire()
        let server = MCPServer(mode: .tools, version: "9", send: { wire.add($0) })
        await server.hub(.connected)
        await server.hub(.message(.hello(hubId: "h")))
        for (index, event) in events.enumerated() { await server.hub(.message(.event(HubEnvelope(id: index + 1, event: event)))) }
        await server.hub(.message(.sync))
        return (server, wire)
    }

    private func reply(_ wire: Wire, _ id: Int) -> (isError: Bool, text: String) {
        let result = wire.reply(id: id)?["result"] as? [String: Any]
        return (result?["isError"] as? Bool == true, ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "")
    }

    @Test("終了の出来事の資料へ、サマリーを入れて、PDF のパスを返す。書く場所は、出来事のパスだけ")
    func savesIntoTheReportOfTheEndedMeeting() async throws {
        let directory = tempDirectory().appendingPathComponent("sessions/s1", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent().deletingLastPathComponent()) }
        let pdf = try ReportBuilder.write(sampleData(), summary: nil, in: directory).get()
        let (server, wire) = await serve([ended("s1", report: pdf.path)])
        await server.handle(line: rpc(1, ["summary": "## 決定事項\n- 金曜にテスト環境を確認"]))
        let result = reply(wire, 1)
        #expect(!result.isError && result.text.contains(pdf.path))
        let text = PDFDocument(url: pdf)?.string ?? ""
        #expect(text.contains("決定事項") && text.contains("金曜にテスト環境を確認"))
    }

    @Test("資料の無い会議・終了していない会議・空のサマリー・長すぎるサマリーは、エラーで返し、何も書かない")
    func rejections() async throws {
        let (server, wire) = await serve([ended("s1", report: nil)])
        await server.handle(line: rpc(1, ["summary": "要約"]))
        #expect(reply(wire, 1).isError, "資料の無い会議")
        await server.handle(line: rpc(2, ["summary": "   "]))
        #expect(reply(wire, 2).isError, "空のサマリー")
        await server.handle(line: rpc(3, ["summary": String(repeating: "あ", count: 100_001)]))
        #expect(reply(wire, 3).isError, "長すぎるサマリー")
        let (idle, idleWire) = await serve([])
        await idle.handle(line: rpc(1, ["summary": "要約"]))
        #expect(reply(idleWire, 1).isError, "会議が終わっていない")
    }

    @Test("session_id を指定すると、その会議の資料に入れる。無い ID は、エラー")
    func selectsBySessionId() async throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ReportBuilder.write(sampleData(), summary: nil, in: root.appendingPathComponent("sessions/a", isDirectory: true)).get()
        let second = try ReportBuilder.write(sampleData(), summary: nil, in: root.appendingPathComponent("sessions/b", isDirectory: true)).get()
        let (server, wire) = await serve([ended("a", report: first.path), ended("b", report: second.path)])
        await server.handle(line: rpc(1, ["summary": "古い会議の要約", "session_id": "a"]))
        #expect(!reply(wire, 1).isError)
        #expect((PDFDocument(url: first)?.string ?? "").contains("古い会議の要約") && !(PDFDocument(url: second)?.string ?? "").contains("古い会議の要約"))
        await server.handle(line: rpc(2, ["summary": "x", "session_id": "nope"]))
        #expect(reply(wire, 2).isError)
    }
}
