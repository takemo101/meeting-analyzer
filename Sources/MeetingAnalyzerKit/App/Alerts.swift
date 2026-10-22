import AppKit

/// 失敗を、利用者に見せるダイアログ。
@MainActor
enum Alerts {
    /// `settings` があれば、「システム設定を開く」のボタンを付ける。
    static func show(title: String, text: String, settings: URL? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        if settings != nil { alert.addButton(withTitle: "システム設定を開く") }
        alert.addButton(withTitle: settings == nil ? "OK" : "閉じる")
        if alert.runModal() == .alertFirstButtonReturn, let settings { NSWorkspace.shared.open(settings) }
    }
}
