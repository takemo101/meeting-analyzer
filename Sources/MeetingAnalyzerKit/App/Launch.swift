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
            return makeRunner().report(error)
        case .success(let command):
            return await makeRunner().run(command)
        }
    }


    /// 標準出力・標準エラーが端末なら、人が読む形で出す（そうでなければ JSON）。
    private static func makeRunner() -> CLIRunner {
        CLIRunner(
            out: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
            err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
            outIsTerminal: isatty(STDOUT_FILENO) == 1,
            errIsTerminal: isatty(STDERR_FILENO) == 1
        )
    }

    public static func isGUILaunch(_ arguments: [String]) -> Bool {
        if case .success(.gui) = CommandParser.parse(arguments) { return true }
        return false
    }

    /// `…/X.app/Contents/MacOS/Y` の形の実行ファイルから、`X.app` のパス。その形でなければ `nil`。
    static func bundlePath(forExecutable path: String) -> String? {
        let marker = ".app/Contents/MacOS/"
        guard let range = path.range(of: marker, options: .backwards) else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// 端末から、引数なしで実行されたとき：その端末の子ではなく、アプリとして（LaunchServices で）起動して、すぐ戻る。
    /// 端末の子のままだと、端末が閉じると終了し、マイク・画面収録の許可の確認も、このアプリでなく、端末のものとして出てしまう。
    /// アプリの中の実行ファイルでなければ（`swift run` など）、`false`（そのまま起動する）。
    public static func openAppFromTerminal() -> Bool {
        guard let executable = Bundle.main.executablePath,
              let bundle = bundlePath(forExecutable: URL(fileURLWithPath: executable).resolvingSymlinksInPath().path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [bundle]
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        FileHandle.standardOutput.write(Data("\(AppInfo.name): メニューバーのアプリを起動しました（すでに起動中なら、そのままです）\n".utf8))
        return true
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
