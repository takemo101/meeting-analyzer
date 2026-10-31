import Foundation

/// アプリに同梱したファイル（`Contents/Resources/<名前>`）の探索。実行ファイルは `Contents/MacOS/` にある。
/// プリセット（`PresetStore`）と、エージェントの起動（`AgentLauncher`）が、同じ探し方を使う。
public enum BundledResources {
    /// いま動いている実行ファイルの実パス（シンボリックリンク経由で起動されても、実体を指す）。
    public static func currentExecutablePath() -> String {
        URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }

    /// `Contents/Resources/<name>` の絶対パス。読めなければ（開発中の実行ファイルなど）`nil`。シンボリックリンク経由でも、実パスで探す。
    public static func path(_ name: String, executable: String) -> String? {
        let resources = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let file = resources.appendingPathComponent(name).path
        return FileManager.default.isReadableFile(atPath: file) ? file : nil
    }
}
