import AppKit

/// `ACTOR.md` を選ぶパネル（メニューと設定ウィンドウが使う。利用者への見せ方は、View 側の責務）。選ばなかったら `nil`。
@MainActor
enum ActorFilePicker {
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.title = "アクター定義（ACTOR.md）を選ぶ"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .init(filenameExtension: "md") ?? .plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
