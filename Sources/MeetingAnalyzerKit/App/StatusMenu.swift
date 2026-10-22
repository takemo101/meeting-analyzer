import AppKit

/// メニューバーの項目。メニューは、開くたびに、会議の状態から作り直す（会議が実行中でないとき、何も動かさない）。
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let controller: MeetingController

    init(controller: MeetingController) {
        self.controller = controller
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        controller.onChange = { [weak self] in self?.refreshIcon() }
        refreshIcon()
    }

    /// メニューバーの絵で、取り込み中・一時停止中・処理中を示す（SPEC §3.10）。
    private func refreshIcon() {
        guard let button = item.button else { return }
        let (symbol, label): (String, String)
        switch controller.state {
        case .idle: (symbol, label) = ("waveform", "待機中")
        case .running: (symbol, label) = ("waveform.circle.fill", "取り込み中")
        case .paused: (symbol, label) = ("pause.circle.fill", "一時停止中")
        case .working: (symbol, label) = ("ellipsis.circle", "処理中")
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "\(AppInfo.name): \(label)")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "\(AppInfo.name): \(label)"
        button.setAccessibilityLabel("\(AppInfo.name): \(label)")
    }

    // MARK: メニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        menu.addItem(label("\(AppInfo.name) \(AppInfo.version)"))
        menu.addItem(label("状態: " + stateText()))
        if let notice = controller.notice { menu.addItem(label(notice)) }
        menu.addItem(.separator())

        switch controller.state {
        case .idle:
            menu.addItem(appsItem())
            let start = action("開始…", #selector(start))
            start.isEnabled = controller.selectedApp != nil
            menu.addItem(start)
        case .running:
            menu.addItem(action("一時停止", #selector(pause)))
            menu.addItem(action("会議を終了", #selector(endMeeting)))
        case .paused:
            menu.addItem(action("再開", #selector(resume)))
            menu.addItem(action("会議を終了", #selector(endMeeting)))
        case .working:
            break
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func stateText() -> String {
        switch controller.state {
        case .idle: return "待機中"
        case .running: return "実行中（\(controller.selectedApp?.name ?? "")）"
        case .paused: return "一時停止中"
        case .working(let text): return text
        }
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    /// 会議アプリの選択。起動中のアプリから選ぶ（相手の音は、選んだアプリだけを取る）。
    private func appsItem() -> NSMenuItem {
        let selected = controller.selectedApp
        let item = NSMenuItem(title: "会議アプリ: " + (selected?.name ?? "未選択"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let apps = controller.candidateApps()
        if apps.isEmpty {
            submenu.addItem(label("起動中のアプリがありません"))
        }
        for app in apps {
            let entry = NSMenuItem(title: app.name, action: #selector(selectApp(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = app.bundleID
            entry.state = app.bundleID == selected?.bundleID ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func selectApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String,
              let app = controller.candidateApps().first(where: { $0.bundleID == bundleID }) else { return }
        controller.select(app)
    }

    @objc private func start() { controller.start() }
    @objc private func pause() { controller.pause() }
    @objc private func resume() { controller.resume() }
    @objc private func endMeeting() { controller.endFromMenu() }
}
