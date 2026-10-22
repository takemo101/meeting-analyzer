import Foundation

/// コマンド `meeting-analyzer`：`/usr/local/bin/meeting-analyzer` から、このアプリの実行ファイルへの、シンボリックリンク（SPEC §3.9）。
/// コピーでなく、アプリのパスへのリンクなので、アプリを更新しても、最新の実行ファイルを指し続ける。メニューから、入れる・外す。
/// 参考：shortnote の `snote`（同じ方式）。
struct CommandLineTool {
    enum State: Equatable {
        /// 安定した場所のアプリから動いていない（`swift run`、隔離〔translocation〕された起動など）。リンクを張れない。
        case unavailable
        case notInstalled
        case installed
        /// 同じパスの、リンクが、別の場所の（または、もう無い）このアプリの実行ファイルを指している（アプリを移した・消した、ビルドしたコピーから張った、など）。付け替えられる。
        case stale(String)
        /// 同じパスに、このアプリではない、別のもの（ファイル、別のツールへのリンク）がある。上書きも削除もしない。
        case other(String)
    }

    /// 管理者の権限でシェルのコマンドを実行する。成功か、取り消しなら `nil`。失敗なら、利用者に見せるメッセージ。
    typealias AdminRunner = (String) -> String?

    static let name = "meeting-analyzer"
    static let defaultLinkPath = "/usr/local/bin/meeting-analyzer"

    let linkPath: String
    /// リンク先にする、アプリの実行ファイル（リンクを辿ったもの）。無ければ、リンクできない。
    let target: String?
    private let runAsAdministrator: AdminRunner

    init(linkPath: String = CommandLineTool.defaultLinkPath, target: String? = CommandLineTool.currentTarget, runAsAdministrator: @escaping AdminRunner = CommandLineTool.appleScriptAdmin) {
        self.linkPath = linkPath
        self.target = target
        self.runAsAdministrator = runAsAdministrator
    }

    /// いま動いているアプリの実行ファイル。`.app` の中で、隔離されていないときだけ。
    static var currentTarget: String? {
        guard let path = Bundle.main.executablePath else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard looksLikeMeetingAnalyzer(resolved), !resolved.contains("/AppTranslocation/") else { return nil }
        return resolved
    }

    var state: State {
        guard let target else { return .unavailable }
        let fileManager = FileManager.default
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkPath) else {
            return fileManager.fileExists(atPath: linkPath) ? .other(linkPath) : .notInstalled
        }
        let directory = (linkPath as NSString).deletingLastPathComponent
        let resolved = URL(fileURLWithPath: destination, relativeTo: URL(fileURLWithPath: directory)).resolvingSymlinksInPath().path
        if resolved == target { return .installed }
        return Self.looksLikeMeetingAnalyzer(resolved) ? .stale(resolved) : .other(resolved)
    }

    /// アプリの実行ファイル（`…/Contents/MacOS/MeetingAnalyzer`）の形か。リンク先が、もう無くても、名前の形で見分ける。
    static func looksLikeMeetingAnalyzer(_ path: String) -> Bool {
        path.hasSuffix(".app/Contents/MacOS/MeetingAnalyzer")
    }

    /// リンクを張る（`state` が `.stale` なら、付け替える）。ディレクトリに書けなければ、管理者のパスワードを求める。成功か、取り消しなら `nil`。失敗なら、メッセージ。
    /// このアプリではない、別のもの（`.other`）があるときは、上書きしない。
    func install() -> String? {
        guard let target else { return "meeting-analyzer を「アプリケーション」フォルダへ移してから、実行してください" }
        let replacing: Bool
        switch state {
        case .installed: return nil
        case .other(let path): return "\(linkPath) には、別のもの（\(path)）があります。上書きしません"
        case .stale: replacing = true
        case .unavailable, .notInstalled: replacing = false
        }
        let directory = (linkPath as NSString).deletingLastPathComponent
        if FileManager.default.isWritableFile(atPath: directory) {
            do {
                if replacing { try FileManager.default.removeItem(atPath: linkPath) }
                try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
                return nil
            } catch { return error.localizedDescription }
        }
        return runAsAdministrator(Self.installScript(directory: directory, target: target, link: linkPath, replacing: replacing))
    }

    /// 自分のリンク（`installed`、または、別の場所のこのアプリを指す `stale`）だけを消す。別のものは消さない。
    func uninstall() -> String? {
        switch state {
        case .installed, .stale: break
        default: return nil
        }
        let directory = (linkPath as NSString).deletingLastPathComponent
        if FileManager.default.isWritableFile(atPath: directory) {
            do { try FileManager.default.removeItem(atPath: linkPath); return nil } catch { return error.localizedDescription }
        }
        return runAsAdministrator("rm -f \(Self.shellQuote(linkPath))")
    }

    /// 管理者の権限で実行するシェルのコマンド（ディレクトリを作り、リンクを張る。`replacing` でなければ、すでに別のものがあっても、上書きしない `ln -s`）。
    static func installScript(directory: String, target: String, link: String, replacing: Bool = false) -> String {
        "mkdir -p \(shellQuote(directory)) && ln -s\(replacing ? "fn" : "") \(shellQuote(target)) \(shellQuote(link))"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 管理者のパスワードを求めて、シェルのコマンドを実行する（`do shell script … with administrator privileges`）。
    static let appleScriptAdmin: AdminRunner = { command in
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        guard let error else { return nil }
        if error[NSAppleScript.errorNumber] as? Int == -128 { return nil }   // パスワードの入力を取り消した
        return error[NSAppleScript.errorMessage] as? String ?? "コマンドを入れられませんでした"
    }
}
