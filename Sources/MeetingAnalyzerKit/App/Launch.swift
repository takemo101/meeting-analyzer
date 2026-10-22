import AppKit
import Foundation

/// メニューバーのアプリ。Dock にもウィンドウにも出さず、メニューバーの項目だけを置く（SPEC §3.1）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenu()
    }
}

/// 起動の入口。引数が無ければメニューバーのアプリを起動して戻らない。CLI のコマンドなら、実行して終了コードを返す。
public enum MeetingAnalyzerApp {
    /// CLI の実行。GUI の起動（引数なし）は `launchGUI()` を使う。
    public static func runCLI(_ arguments: [String]) async -> Int32 {
        switch CommandParser.parse(arguments) {
        case .failure(let error):
            FileHandle.standardError.write(Data((CLIRunner.json(["ok": false, "code": error.code, "message": error.message]) + "\n").utf8))
            return error.exitCode
        case .success(let command):
            let runner = CLIRunner(
                out: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
                err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
            )
            return await runner.run(command)
        }
    }

    public static func isGUILaunch(_ arguments: [String]) -> Bool {
        if case .success(.gui) = CommandParser.parse(arguments) { return true }
        return false
    }

    /// メニューバーのアプリを起動する。終了するまで戻らない。
    @MainActor
    public static func launchGUI() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
