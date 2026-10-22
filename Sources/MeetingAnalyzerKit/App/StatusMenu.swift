import AppKit

/// メニューバーの項目。いまは、版と状態を出して、終了できるだけ（音声・画面の取り込みは、SPEC の後続の項目）。
@MainActor
final class StatusMenu {
    private let item: NSStatusItem

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: AppInfo.name)
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel(AppInfo.name)
        }
        let menu = NSMenu()
        let title = NSMenuItem(title: "\(AppInfo.name) \(AppInfo.version)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let state = NSMenuItem(title: "状態: 待機中", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }
}
