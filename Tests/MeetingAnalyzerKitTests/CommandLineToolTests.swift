import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("CommandLineTool: コマンド meeting-analyzer の、リンクの入れ・外し")
struct CommandLineToolTests {
    private let appExecutable = "/Applications/MeetingAnalyzer.app/Contents/MacOS/MeetingAnalyzer"

    /// 書き込める一時ディレクトリを、リンクの置き場にする。管理者の実行は、呼ばれたコマンドを記録するだけ。
    private func makeTool(target: String? = "/Applications/MeetingAnalyzer.app/Contents/MacOS/MeetingAnalyzer", directory: URL, admin: @escaping CommandLineTool.AdminRunner = { _ in nil }) -> CommandLineTool {
        CommandLineTool(linkPath: directory.appendingPathComponent("meeting-analyzer").path, target: target, runAsAdministrator: admin)
    }

    @Test("入れる → installed、外す → notInstalled")
    func installAndUninstall() throws {
        let dir = tempURL("cmd")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = makeTool(directory: dir)
        #expect(tool.state == .notInstalled)
        #expect(tool.install() == nil)
        #expect(tool.state == .installed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: tool.linkPath) == appExecutable)
        #expect(tool.uninstall() == nil)
        #expect(tool.state == .notInstalled)
    }

    @Test("別の場所のこのアプリを指すリンクは、stale。付け替えられ、外せる")
    func staleIsReplaced() throws {
        let dir = tempURL("cmd-stale")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = "/Old/MeetingAnalyzer.app/Contents/MacOS/MeetingAnalyzer"
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("meeting-analyzer").path, withDestinationPath: old)
        let tool = makeTool(directory: dir)
        #expect(tool.state == .stale(old))
        #expect(tool.install() == nil)
        #expect(tool.state == .installed)
    }

    @Test("別のもの（ファイル・別のツールへのリンク）は、上書きも削除もしない")
    func otherIsNeverTouched() throws {
        let dir = tempURL("cmd-other")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("meeting-analyzer").path
        FileManager.default.createFile(atPath: link, contents: Data("x".utf8))
        let tool = makeTool(directory: dir)
        #expect(tool.state == .other(link))
        #expect(tool.install() != nil)
        #expect(tool.uninstall() == nil)
        #expect(FileManager.default.fileExists(atPath: link), "ファイルは、そのまま残る")

        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/usr/bin/true")
        #expect(tool.state == .other("/usr/bin/true"))
        #expect(tool.install() != nil)
        #expect(tool.uninstall() == nil)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == "/usr/bin/true")
    }

    @Test("アプリが安定した場所から動いていない（target なし）なら、unavailable で、入れられない")
    func unavailableWithoutTarget() throws {
        let dir = tempURL("cmd-none")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = makeTool(target: nil, directory: dir)
        #expect(tool.state == .unavailable)
        #expect(tool.install() != nil)
        #expect(!FileManager.default.fileExists(atPath: tool.linkPath))
    }

    @Test("ディレクトリに書けないときは、管理者の実行へ回る：作る・付け替えのコマンドの形と、取り消し・失敗の返り方")
    func administratorPath() {
        var commands: [String] = []
        let tool = CommandLineTool(linkPath: "/nonexistent-root/bin/meeting-analyzer", target: appExecutable) { command in
            commands.append(command)
            return "拒否された"
        }
        #expect(tool.install() == "拒否された", "管理者の実行の失敗は、そのまま返る")
        #expect(commands == ["mkdir -p '/nonexistent-root/bin' && ln -s '\(appExecutable)' '/nonexistent-root/bin/meeting-analyzer'"])
        #expect(CommandLineTool.installScript(directory: "/d", target: "/t", link: "/d/l", replacing: true) == "mkdir -p '/d' && ln -sfn '/t' '/d/l'")
    }

    @Test("実行ファイルから、アプリ（.app）のパスを求める：.app の中の実行ファイルだけ")
    func bundlePath() {
        #expect(MeetingAnalyzerApp.bundlePath(forExecutable: "/Applications/MeetingAnalyzer.app/Contents/MacOS/MeetingAnalyzer") == "/Applications/MeetingAnalyzer.app")
        #expect(MeetingAnalyzerApp.bundlePath(forExecutable: "/a/b.app/x/Foo.app/Contents/MacOS/Foo") == "/a/b.app/x/Foo.app", "入れ子なら、いちばん内側")
        #expect(MeetingAnalyzerApp.bundlePath(forExecutable: "/repo/.build/debug/MeetingAnalyzer") == nil)
    }

    @Test("パスの引用：空白・単一引用符を含んでも、シェルが 1 語として読む")
    func shellQuoting() {
        #expect(CommandLineTool.shellQuote("/Users/a b/it's") == "'/Users/a b/it'\\''s'")
    }
}
