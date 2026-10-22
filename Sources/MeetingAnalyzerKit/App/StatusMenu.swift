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
        menu.addItem(label(agentText()))
        if let notice = controller.notice { menu.addItem(label(notice)) }
        menu.addItem(.separator())

        switch controller.state {
        case .idle:
            menu.addItem(microphoneItem())
            menu.addItem(systemItem())
            menu.addItem(screenItem())
            menu.addItem(batchModeItem())
            menu.addItem(reportItem())
            let start = action("開始", #selector(start))
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
        if let report = controller.lastReport, FileManager.default.fileExists(atPath: report.path) {
            menu.addItem(.separator())
            menu.addItem(action("直前の資料（PDF）を開く", #selector(openReport)))
        }
        menu.addItem(.separator())
        menu.addItem(registrationItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// 文字起こしを受け取っているエージェント（`meeting-analyzer mcp`）の数。
    private func agentText() -> String {
        controller.agentCount == 0 ? "エージェント: 未接続" : "エージェント: \(controller.agentCount) 件接続中"
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

    /// エージェントへの登録の文のコピー（MCP サーバー `mcp` を、エージェントに登録する）。
    private func registrationItem() -> NSMenuItem {
        let item = NSMenuItem(title: "エージェントに登録（コピー）", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, registration) in AgentRegistration.allCases.enumerated() {
            let entry = NSMenuItem(title: registration.title, action: #selector(copyRegistration(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func copyRegistration(_ sender: NSMenuItem) {
        guard AgentRegistration.allCases.indices.contains(sender.tag) else { return }
        controller.copyRegistration(AgentRegistration.allCases[sender.tag])
    }

    /// 画面の取り込み：オフ・画面全体・起動中のアプリのウィンドウ。変化があったときだけ、縮小した画像を、字幕に添えて渡す。
    private func screenItem() -> NSMenuItem {
        let current = controller.screen
        let item = NSMenuItem(title: "画面の取り込み: " + current.title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        func entry(_ title: String, _ selection: ScreenSelection) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: #selector(selectScreen(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = ScreenChoice(selection: selection)
            entry.state = current == selection ? .on : .off
            return entry
        }
        submenu.addItem(entry("オフ", .off))
        submenu.addItem(entry("画面全体（メインの画面）", .display))
        submenu.addItem(.separator())
        submenu.addItem(label("アプリのウィンドウ"))
        let apps = controller.candidateApps()
        if apps.isEmpty { submenu.addItem(label("起動中のアプリがありません")) }
        for app in apps { submenu.addItem(entry(app.name, .app(bundleID: app.bundleID, name: app.name))) }
        item.submenu = submenu
        return item
    }

    private final class ScreenChoice: NSObject {
        let selection: ScreenSelection
        init(selection: ScreenSelection) { self.selection = selection }
    }

    @objc private func selectScreen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ScreenChoice else { return }
        controller.setScreen(choice.selection)
    }

    /// エージェントへ渡す、まとめ方（発話の区切り／会話の区切り／約 30 秒／約 5 秒）。
    private func batchModeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "転送のまとめ方: " + controller.batchMode.title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, mode) in BatchMode.allCases.enumerated() {
            let entry = NSMenuItem(title: mode.title, action: #selector(selectBatchMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = mode == controller.batchMode ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func selectBatchMode(_ sender: NSMenuItem) {
        guard BatchMode.allCases.indices.contains(sender.tag) else { return }
        controller.setBatchMode(BatchMode.allCases[sender.tag])
    }

    /// 会議のあとの資料：なし／PDF。PDF は、記録と画面（と、エージェントが渡したサマリー）を 1 つにする。画面の画像は、資料のために、記録の下へ残る。
    private func reportItem() -> NSMenuItem {
        let item = NSMenuItem(title: "終了後の資料: " + controller.reportMode.title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for (index, mode) in ReportMode.allCases.enumerated() {
            let entry = NSMenuItem(title: mode.title, action: #selector(selectReport(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = mode == controller.reportMode ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func selectReport(_ sender: NSMenuItem) {
        guard ReportMode.allCases.indices.contains(sender.tag) else { return }
        controller.setReport(ReportMode.allCases[sender.tag])
    }

    @objc private func openReport() { controller.openLastReport() }

    /// マイク（本人）のオン／オフ。
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
