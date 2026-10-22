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
            menu.addItem(microphoneItem())
            menu.addItem(systemItem())
            let start = action("開始…", #selector(start))
            start.isEnabled = !controller.selection.isEmpty
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
        case .running: return "実行中（\(controller.selection.summary)）"
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

    /// マイク（あなた）のオン／オフ。
    private func microphoneItem() -> NSMenuItem {
        let item = action("マイク", #selector(toggleMicrophone))
        item.state = controller.selection.microphone ? .on : .off
        return item
    }

    /// システム音声（相手）の選択：オフ・全体・起動中のアプリ。
    private func systemItem() -> NSMenuItem {
        let current = controller.selection.system
        let title: String
        switch current {
        case .off: title = "オフ"
        case .all: title = "全体"
        case .app(_, let name): title = name
        }
        let item = NSMenuItem(title: "システム音声: " + title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let off = NSMenuItem(title: "オフ", action: #selector(selectSystem(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = SystemChoice(source: .off)
        off.state = current == .off ? .on : .off
        submenu.addItem(off)

        let all = NSMenuItem(title: "全体（Mac から出ている音すべて）", action: #selector(selectSystem(_:)), keyEquivalent: "")
        all.target = self
        all.representedObject = SystemChoice(source: .all)
        all.state = current == .all ? .on : .off
        submenu.addItem(all)

        submenu.addItem(.separator())
        submenu.addItem(label("アプリを選ぶ"))
        let apps = controller.candidateApps()
        if apps.isEmpty { submenu.addItem(label("起動中のアプリがありません")) }
        for app in apps {
            let entry = NSMenuItem(title: app.name, action: #selector(selectSystem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = SystemChoice(source: .app(bundleID: app.bundleID, name: app.name))
            if case .app(let id, _) = current, id == app.bundleID { entry.state = .on }
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    /// メニュー項目に持たせる選択（`representedObject` は参照型のみ）。
    private final class SystemChoice: NSObject {
        let source: SystemSource
        init(source: SystemSource) { self.source = source }
    }

    @objc private func toggleMicrophone() { controller.setMicrophone(!controller.selection.microphone) }

    @objc private func selectSystem(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SystemChoice else { return }
        controller.setSystem(choice.source)
    }

    @objc private func start() { controller.start() }
    @objc private func pause() { controller.pause() }
    @objc private func resume() { controller.resume() }
    @objc private func endMeeting() { controller.endFromMenu() }
}
