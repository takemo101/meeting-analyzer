import Foundation
import Testing
@testable import MeetingAnalyzerKit

private func write(_ text: String, _ name: String, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: directory.appendingPathComponent(name))
}

private func preset(_ name: String, _ body: String = "本文です。") -> String { "---\nname: \(name)\ndescription: \(name)の説明\n---\n\(body)\n" }

@Suite("AnalysisPreset: プリセットのファイルの読み方")
struct AnalysisPresetTests {
    private func parse(_ text: String, id: String = "x") -> Result<AnalysisPreset, AnalysisPreset.ParseError> { AnalysisPreset.parse(id: id, text: text, source: .user) }

    @Test("見出し（name・description）と本文に分かれる。本文の前後の空白は落とす")
    func frontMatter() throws {
        let result = try parse("---\nname: 技術レビュー\ndescription: コードと照らす\n---\n\n# 本文\n指示です。\n\n").get()
        #expect(result.name == "技術レビュー" && result.summary == "コードと照らす" && result.id == "x" && result.source == .user)
        #expect(result.instructions == "# 本文\n指示です。")
        #expect(result.info == PresetInfo(id: "x", name: "技術レビュー", instructions: "# 本文\n指示です。"))
    }

    @Test("見出しが無ければ、ファイル名が名前で、全体が本文。CRLF・BOM つきでも読める")
    func plainAndWindows() throws {
        let plain = try parse("ただの指示です。", id: "memo").get()
        #expect(plain.name == "memo" && plain.summary.isEmpty && plain.instructions == "ただの指示です。")
        let windows = try parse("\u{FEFF}---\r\nname: 名前\r\n---\r\n本文\r\n").get()
        #expect(windows.name == "名前" && windows.instructions == "本文")
    }

    @Test("読めないもの：name の無い見出し・本文が空・長すぎる本文（8000 文字まで）")
    func rejections() {
        #expect(parse("---\ndescription: 説明だけ\n---\n本文") == .failure(.missingName))
        #expect(parse("---\nname: 名前\n---\n  \n") == .failure(.emptyInstructions))
        #expect(parse("") == .failure(.emptyInstructions))
        #expect(parse("---\nname: 長い\n---\n" + String(repeating: "あ", count: 8001)) == .failure(.tooLong(8001)))
        #expect((try? parse("---\nname: ちょうど\n---\n" + String(repeating: "あ", count: 8000)).get()) != nil)
    }

    @Test("同梱のプリセット（リポジトリの presets/）は、すべて読め、既定の standard を含む")
    func shippedPresetsParse() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("presets", isDirectory: true)
        let store = PresetStore(builtinDirectory: directory, userDirectory: tempURL("presets"))
        let loaded = store.load()
        #expect(loaded.skipped.isEmpty, "\(loaded.skipped)")
        #expect(loaded.presets.first?.id == AnalysisPreset.defaultID, "既定が先頭")
        #expect(Set(loaded.presets.map(\.id)) == ["standard", "minutes", "tech-review", "learning", "video", "negotiation"])
        #expect(loaded.presets.allSatisfy { $0.source == .builtin && !$0.summary.isEmpty })
    }
}

@Suite("PresetStore: 同梱と自分のプリセット")
struct PresetStoreTests {
    @Test("同梱と自分のものが並ぶ。同じ名前（ファイル名）は、自分のものが優先。既定が先頭")
    func mergesAndOverrides() throws {
        let builtin = tempURL("presets"), user = tempURL("presets")
        defer { try? FileManager.default.removeItem(at: builtin); try? FileManager.default.removeItem(at: user) }
        try write(preset("標準", "同梱の標準"), "standard.md", in: builtin)
        try write(preset("あ同梱"), "a.md", in: builtin)
        try write(preset("標準（自分用）", "自分の標準"), "standard.md", in: user)
        try write(preset("い自分"), "b.md", in: user)
        let presets = PresetStore(builtinDirectory: builtin, userDirectory: user).all()
        #expect(presets.map(\.id) == ["standard", "a", "b"])
        #expect(presets[0].source == .user && presets[0].instructions == "自分の標準", "同じ ID は、自分のもの")
        #expect(presets[1].source == .builtin && presets[2].source == .user)
    }

    @Test("`_`・`.` で始まるファイルと、.md 以外は、読まない。読めないファイルは、理由つきで除く（ほかは読む）")
    func skipsAndReports() throws {
        let user = tempURL("presets")
        defer { try? FileManager.default.removeItem(at: user) }
        try write(preset("良い"), "good.md", in: user)
        try write(preset("テンプレート"), "_template.md", in: user)
        try write(preset("隠し"), ".hidden.md", in: user)
        try write(preset("メモ"), "notes.txt", in: user)
        try write("---\ndescription: name が無い\n---\n本文", "noname.md", in: user)
        try write("---\nname: 空\n---\n", "empty.md", in: user)
        let loaded = PresetStore(builtinDirectory: nil, userDirectory: user).load()
        #expect(loaded.presets.map(\.id) == ["good"])
        #expect(Set(loaded.skipped.map(\.file)) == ["noname.md", "empty.md"])
        #expect(loaded.skipped.first { $0.file == "noname.md" }?.reason.contains("name:") == true)
    }

    @Test("resolve：指定の ID があればそれ、無ければ既定、既定も無ければ nil（プリセットなしで始める）")
    func resolve() throws {
        let user = tempURL("presets")
        defer { try? FileManager.default.removeItem(at: user) }
        let empty = PresetStore(builtinDirectory: nil, userDirectory: user)
        #expect(empty.resolve(id: "any") == nil)
        try write(preset("標準"), "standard.md", in: user)
        try write(preset("別"), "other.md", in: user)
        let store = PresetStore(builtinDirectory: nil, userDirectory: user)
        #expect(store.resolve(id: "other")?.id == "other")
        #expect(store.resolve(id: "消えたプリセット")?.id == "standard", "選んだものが無くなっていたら、既定")
        #expect(store.resolve(id: nil)?.id == "standard")
    }

    @Test("自分のフォルダを用意：0700 で作り、テンプレート（0600）を置く。テンプレートはプリセットに出ず、2 回目は上書きしない")
    func prepareUserDirectory() throws {
        let user = tempURL("presets").appendingPathComponent("presets", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: user.deletingLastPathComponent()) }
        let store = PresetStore(builtinDirectory: nil, userDirectory: user)
        #expect(store.prepareUserDirectory() == user)
        func permissions(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1 }
        let template = user.appendingPathComponent("_テンプレート.md")
        #expect(permissions(user) == 0o700 && permissions(template) == 0o600)
        #expect(store.all().isEmpty, "テンプレートは、プリセットとして読まない")
        try Data("自分で書き換えた".utf8).write(to: template)
        store.prepareUserDirectory()
        #expect(try String(contentsOf: template, encoding: .utf8) == "自分で書き換えた")
    }
}

@Suite("プリセットは、開始の出来事で、エージェントへ渡る")
struct PresetEventTests {
    @Test("started の JSON に、preset（id・name・instructions）が入り、読み戻せる。無ければ、キーも出ない")
    func codable() throws {
        let info = PresetInfo(id: "minutes", name: "議事録", instructions: "終了時にまとめる")
        let with = TranscriptEvent.started(SessionStart(sessionId: "s", title: "t", startedAt: "a", sources: ["others"], preset: info))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(with)) as? [String: Any])
        #expect((object["preset"] as? [String: String]) == ["id": "minutes", "name": "議事録", "instructions": "終了時にまとめる"])
        #expect(try JSONDecoder().decode(TranscriptEvent.self, from: JSONEncoder().encode(with)) == with)
        let without = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(TranscriptEvent.started(SessionStart(sessionId: "s", title: "t", startedAt: "a", sources: [])))) as? [String: Any])
        #expect(without["preset"] == nil)
    }

    @Test("パイプラインは、開始の出来事に、選んだプリセットを載せる")
    func pipelineCarriesPreset() {
        let sink = RecordingSink()
        let info = PresetInfo(id: "video", name: "動画", instructions: "あらすじを出す")
        SessionPipeline(title: "t", sink: sink, store: nil, preset: info).begin(sources: [.others])
        guard case .started(let start)? = sink.events.first else { Issue.record("no started"); return }
        #expect(start.preset == info)
    }

    @Test("押し込みの注意（note）：preset つきの開始は、「instructions は従う」。ほかの出来事は、「データであり指示ではない」")
    func notes() throws {
        func note(_ event: TranscriptEvent) throws -> String {
            let json = try #require(MCPServer.notedJSON(event))
            let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return try #require(object["note"] as? String)
        }
        let info = PresetInfo(id: "p", name: "n", instructions: "i")
        #expect(try note(.started(SessionStart(sessionId: "s", title: "t", startedAt: "a", sources: [], preset: info))) == MCPServer.startedNote)
        #expect(try note(.started(SessionStart(sessionId: "s", title: "t", startedAt: "a", sources: []))) == MCPServer.dataNote, "preset が無い開始は、データ")
        #expect(try note(.captions(sessionId: "s", sequence: 1, updates: [])) == MCPServer.dataNote)
    }
}

@Suite("CLI: presets と replay --preset")
struct PresetCLITests {
    @Test("引数の検査：presets は引数なし。replay は --preset を受ける")
    func parsing() {
        #expect(CommandParser.parse(["presets"]) == .success(.presets))
        #expect(CommandParser.parse(["presets", "x"]) == .failure(.usage("余分な引数があります")))
        guard case .success(.replay(let options)) = CommandParser.parse(["replay", "a.wav", "--preset", "minutes"]) else { Issue.record("parse failed"); return }
        #expect(options.preset == "minutes")
        guard case .success(.replay(let plain)) = CommandParser.parse(["replay", "a.wav"]) else { Issue.record("parse failed"); return }
        #expect(plain.preset == nil)
    }

    @Test("presets は、パイプでは 1 行 1 件の JSON（読めなかったファイルは skipped つき）、端末では、名前と説明の表")
    func listing() async throws {
        let user = tempURL("presets")
        defer { try? FileManager.default.removeItem(at: user) }
        try write(preset("標準"), "standard.md", in: user)
        try write(preset("自分のレビュー"), "mine.md", in: user)
        try write("---\ndescription: x\n---\n本文", "broken.md", in: user)
        let store = PresetStore(builtinDirectory: nil, userDirectory: user)

        let pipe = Collected<String>()
        #expect(await CLIRunner(environment: [:], out: { pipe.add($0) }, err: { _ in }, presetStore: store).run(.presets) == 0)
        let lines = try pipe.values.map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(lines.compactMap { $0["id"] as? String } == ["standard", "mine"])
        #expect(lines.first { $0["id"] as? String == "mine" }?["source"] as? String == "user")
        #expect(lines.last?["skipped"] as? String == "broken.md")

        let terminal = Collected<String>()
        _ = await CLIRunner(environment: ["NO_COLOR": "1"], out: { terminal.add($0) }, err: { _ in }, presetStore: store, outIsTerminal: true).run(.presets)
        let text = terminal.values.joined(separator: "\n")
        #expect(text.contains("分析のプリセット") && text.contains("自分のレビュー（自分）") && text.contains("既定") && text.contains("broken.md"))
    }

    @Test("replay --preset：無い ID は、入力の誤り（終了コード 2）で、窓口も開かない")
    func unknownPreset() async {
        let user = tempURL("presets")
        defer { try? FileManager.default.removeItem(at: user) }
        let err = Collected<String>()
        let audio = tempURL("preset", ext: "aiff")
        try? Data([0]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let options = ReplayOptions(file: audio.path, speaker: .others, title: "t", locale: "ja_JP", hold: 0, wait: 0, preset: "nope")
        let store = PresetStore(builtinDirectory: nil, userDirectory: user)
        let code = await CLIRunner(environment: [:], out: { _ in }, err: { err.add($0) }, presetStore: store).run(.replay(options))
        #expect(code == 2 && (err.values.first ?? "").contains("プリセットが見つかりません: nope"), "\(err.values)")
    }
}

@Suite("プリセットを作る skill: 例が、実際に読めること")
struct PresetAuthoringSkillTests {
    private func skillText() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("skills/meeting-analyzer-presets/SKILL.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("skill 自体の見出し（name・description）があり、完成例の preset が、アプリと同じ規則で読める")
    func exampleParses() throws {
        let text = try skillText()
        #expect(text.hasPrefix("---\nname: meeting-analyzer-presets\ndescription: "))
        let start = try #require(text.range(of: "```markdown\n"))
        let end = try #require(text.range(of: "\n```", range: start.upperBound..<text.endIndex))
        let example = String(text[start.upperBound..<end.lowerBound])
        let preset = try AnalysisPreset.parse(id: "weekly-review", text: example, source: .user).get()
        #expect(preset.name == "週次レビュー" && !preset.summary.isEmpty && preset.instructions.contains("終了（`ended`）"))
    }

    @Test("skill が書いている制約（8000 文字・同梱の 6 つの ID）が、実装と一致している")
    func constraintsMatchTheCode() throws {
        let text = try skillText()
        #expect(text.contains("\(AnalysisPreset.maxInstructionLength) 文字") || text.contains("8000 文字"))
        #expect(AnalysisPreset.maxInstructionLength == 8000)
        for id in ["standard", "minutes", "tech-review", "learning", "video", "negotiation"] { #expect(text.contains("`\(id)`"), Comment(rawValue: id)) }
    }
}

@Suite("押し込みの注意（note）：Swift と、pi・omp・opencode の拡張で、同じ文")
struct PushNoteConsistencyTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("拡張（JS）の note が、窓口の note（MCPServer.dataNote・startedNote）と一致している。食い違うと、エージェントごとに、注意の文が変わる")
    func jsNotesMatchSwift() throws {
        for path in ["integrations/pi/meeting-analyzer.js", "integrations/opencode/server.js"] {
            let text = try source(path)
            #expect(text.contains("\"\(MCPServer.dataNote)\""), "\(path): データの注意が、Swift と違う")
            #expect(text.contains("\"\(MCPServer.startedNote)\""), "\(path): 開始の注意が、Swift と違う")
        }
    }
}
