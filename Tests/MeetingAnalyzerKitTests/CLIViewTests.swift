import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("CLI の表示: 色は端末のときだけ、桁は日本語でも揃う、パイプには JSON")
struct CLIViewTests {
    private let escape = "\u{1B}"

    @Test("色は、端末で、NO_COLOR が無く、TERM が dumb でないときだけ")
    func colorGating() {
        #expect(TerminalStyle.detect(isTerminal: true, environment: [:]).color)
        #expect(!TerminalStyle.detect(isTerminal: false, environment: [:]).color, "パイプ・ファイルには付けない")
        #expect(!TerminalStyle.detect(isTerminal: true, environment: ["NO_COLOR": "1"]).color)
        #expect(!TerminalStyle.detect(isTerminal: true, environment: ["TERM": "dumb"]).color)
        #expect(TerminalStyle.detect(isTerminal: true, environment: ["NO_COLOR": ""]).color, "空の NO_COLOR は、無指定と同じ（仕様どおり）")
    }

    @Test("色なしの表示に、エスケープシーケンスが混ざらない（ヘルプ・失敗・起動・doctor・再生）")
    func plainHasNoEscapes() {
        let style = TerminalStyle.plain
        let texts = [
            CLIView.help(style),
            CLIView.failure(.usage("x"), style),
            CLIView.launch(agent: .pi, appConnected: false, registration: .registered("/a/b", backedUp: true), registrationText: nil, style),
            CLIView.doctor(SpeechReadiness(locale: "ja_JP", supported: true, installed: false), style),
            CLIView.replaySummary(sessionId: "s", utterances: 2, batches: 1, duration: 65.5, path: "/x", style),
        ]
        for text in texts { #expect(!text.contains(escape), "\(text)") }
        #expect(CLIView.help(TerminalStyle(color: true)).contains(escape))
    }

    @Test("表の桁は、全角を 2 桁として揃える（説明の開始位置が、全行で同じ）")
    func tableAlignsWideCharacters() {
        let rows = TerminalStyle.plain.table([("アプリ", ["a"]), ("MCP 登録", ["b", "c"]), ("字幕", ["d"])])
        let starts = rows.map { row in TerminalStyle.displayWidth(String(row.prefix(while: { $0 != "a" && $0 != "b" && $0 != "c" && $0 != "d" }))) }
        #expect(Set(starts).count == 1, "\(rows)")
        #expect(rows.count == 4, "複数行の説明は、続きの行になる")
    }

    @Test("起動の表示は、エージェントごとに、字幕の届き方を正しく言う")
    func launchDescribesDelivery() {
        let style = TerminalStyle.plain
        func banner(_ agent: LaunchableAgent) -> String { CLIView.launch(agent: agent, appConnected: true, registration: agent == .claude ? nil : .alreadyRegistered("/p"), registrationText: nil, style) }
        #expect(banner(.claude).contains("チャンネル") && !banner(.claude).contains("MCP 登録"), "Claude は、設定を書かない")
        #expect(banner(.pi).contains("拡張") && banner(.omp).contains("拡張"))
        #expect(banner(.opencode).contains("プラグイン") && banner(.opencode).contains("--standalone"))
        let admin = CLIView.launch(agent: .opencode, appConnected: true, registration: .alreadyRegistered("/p"), registrationText: nil, pushes: false, style)
        #expect(admin.contains("自動では届きません"), "管理コマンド（mcp list など）には、プラグインを載せないので、押し込みを約束しない")
        #expect(CLIView.launch(agent: .claude, appConnected: false, registration: nil, registrationText: nil, style).contains("接続できません"))
    }

    @Test("自動で登録できないときは、手で足す文を、そのまま見せる")
    func launchShowsManualRegistration() {
        let text = CLIView.launch(agent: .opencode, appConnected: true, registration: .manual(path: "/c/opencode.json", reason: "コメントを含む"), registrationText: "{ \"mcp\": {} }", .plain)
        #expect(text.contains("/c/opencode.json") && text.contains("{ \"mcp\": {} }") && text.contains("コメントを含む"))
    }

    @Test("時刻は mm:ss.s")
    func clock() {
        #expect(CLIView.clock(0) == "00:00.0")
        #expect(CLIView.clock(65.46) == "01:05.5")
        #expect(CLIView.clock(-3) == "00:00.0")
    }

    @Test("失敗は、端末では人が読む形（JSON でない）、パイプでは 1 行の JSON")
    func failureFollowsTerminal() async {
        for (terminal, expectJSON) in [(true, false), (false, true)] {
            let out = Output(), err = Output()
            let runner = CLIRunner(environment: [:], out: { out.add($0) }, err: { err.add($0) }, errIsTerminal: terminal)
            let code = await runner.run(.transcribe(file: "/no/such/file.wav", locale: "ja_JP"))
            #expect(code == 2)
            let line = err.lines.first ?? ""
            let isJSON = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil
            #expect(isJSON == expectJSON, "terminal=\(terminal): \(line)")
            #expect(line.contains("/no/such/file.wav"))
        }
    }

    @Test("transcribe は、端末では時刻つきの行、パイプでは 1 行 1 件の JSON")
    func transcribeFollowsTerminal() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ma-view-" + UUID().uuidString + ".aiff")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let updates: CLIRunner.UpdatesProvider = { _, _ in
            AsyncThrowingStream { $0.yield(TranscriptionUpdate(text: "こんにちは", isFinal: true, start: 1, end: 2.5)); $0.finish() }
        }
        for terminal in [true, false] {
            let out = Output()
            let code = await CLIRunner(environment: ["NO_COLOR": "1"], out: { out.add($0) }, err: { _ in }, updates: updates, outIsTerminal: terminal).run(.transcribe(file: file.path, locale: "ja_JP"))
            #expect(code == 0)
            let line = try #require(out.lines.first)
            if terminal { #expect(line == "00:01.0 → 00:02.5  こんにちは") } else { #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil) }
        }
    }
}
