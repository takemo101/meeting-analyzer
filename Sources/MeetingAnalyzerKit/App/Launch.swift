import AppKit
import Foundation

/// メニューバーのアプリ。Dock にもウィンドウにも出さず、メニューバーの項目だけを置く（SPEC §3.1）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = MeetingController()
    private var statusMenu: StatusMenu?
    private var termination: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.startHub()
        statusMenu = StatusMenu(controller: controller)
        // SIGTERM も、通常の終了と同じ道（実行中の会議を `appQuit` で終える）を通す。
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termination = source
    }

    /// 実行中・一時停止中の会議は、`appQuit` の理由で終わらせ（記録と終了の合図）、それから終了する（SPEC §3.1）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.hasActiveMeeting else { controller.stopHub(); return .terminateNow }
        Task {
            await controller.end(reason: .appQuit)
            controller.stopHub()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
