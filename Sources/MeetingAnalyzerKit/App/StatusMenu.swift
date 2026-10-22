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
            menu.addItem(presetItem())
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
        menu.addItem(.separator())
        menu.addItem(registrationItem())
        menu.addItem(commandItem())
        menu.addItem(recordsItem())
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

    /// コマンド `meeting-analyzer`（`/usr/local/bin` へのリンク）を、入れる・外す。入っていれば、チェック。
    private func commandItem() -> NSMenuItem {
        let name = CommandLineTool.name
        let state = controller.commandState
        switch state {
        case .unavailable:
            return label("コマンド「\(name)」: アプリを「アプリケーション」へ移すと入れられます")
        case .other(let path):
            return label("コマンド「\(name)」: \(path) に、別のものがあります")
        case .installed:
            let item = action("コマンド「\(name)」をインストール（/usr/local/bin）", #selector(toggleCommand))
            item.state = .on
            return item
        case .stale:
            return action("コマンド「\(name)」を、このアプリへ付け替える", #selector(toggleCommand))
        case .notInstalled:
            return action("コマンド「\(name)」をインストール（/usr/local/bin）", #selector(toggleCommand))
        }
    }

    @objc private func toggleCommand() { controller.toggleCommand() }

    /// 記録（文字起こし・画像）を残す日数と、記録のフォルダ。期限を過ぎた記録は、文字起こしも画像も、フォルダごと消える。
    private func recordsItem() -> NSMenuItem {
        submenuItem("記録の保持期間: " + RecordRetentionSetting.title(controller.retentionDays)) { submenu in
            for days in RecordRetentionSetting.choices {
                submenu.addItem(choice(RecordRetentionSetting.title(days), selected: days == controller.retentionDays) { [controller] in controller.setRetentionDays(days) })
            }
            submenu.addItem(.separator())
            submenu.addItem(action("記録のフォルダを開く", #selector(openRecordsFolder)))
        }
    }

    @objc private func openRecordsFolder() { controller.openRecordsFolder() }

    // MARK: 選択肢のサブメニュー

    /// メニュー項目が選ばれたときの処理（`representedObject` は参照型のみ）。選択肢ごとに、処理を持たせる。
    private final class Choice: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc private func runChoice(_ sender: NSMenuItem) { (sender.representedObject as? Choice)?.run() }

    /// 選択肢 1 つ。`selected` なら、チェックを付ける。
    private func choice(_ title: String, selected: Bool, tooltip: String? = nil, _ run: @escaping () -> Void) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: #selector(runChoice(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = Choice(run)
        entry.state = selected ? .on : .off
        entry.toolTip = tooltip
        return entry
    }

    /// サブメニューを持つ項目。`build` で、サブメニューの中身を作る。
    private func submenuItem(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        build(submenu)
        item.submenu = submenu
        return item
    }

    /// 起動中のアプリの一覧（見出しつき）。1 つも無ければ、その旨を出す。
    private func addApps(to submenu: NSMenu, heading: String, entry: (CaptureApp) -> NSMenuItem) {
        submenu.addItem(.separator())
        submenu.addItem(label(heading))
        let apps = controller.candidateApps()
        if apps.isEmpty { submenu.addItem(label("起動中のアプリがありません")) }
        for app in apps { submenu.addItem(entry(app)) }
    }

    /// エージェントへの登録の文のコピー（MCP サーバー `mcp` を、エージェントに登録する）。
    private func registrationItem() -> NSMenuItem {
        submenuItem("エージェントに登録（コピー）") { submenu in
            for registration in AgentRegistration.allCases {
                submenu.addItem(choice(registration.title, selected: false) { [controller] in controller.copyRegistration(registration) })
            }
        }
    }

    /// 画面の取り込み：オフ・画面全体・起動中のアプリのウィンドウ。変化があったときだけ、縮小した画像を、字幕に添えて渡す。
    private func screenItem() -> NSMenuItem {
        let current = controller.screen
        func entry(_ title: String, _ selection: ScreenSelection) -> NSMenuItem {
            choice(title, selected: current == selection) { [controller] in controller.setScreen(selection) }
        }
        return submenuItem("画面の取り込み: " + current.title) { submenu in
            submenu.addItem(entry("オフ", .off))
            submenu.addItem(entry("画面全体（メインの画面）", .display))
            addApps(to: submenu, heading: "アプリのウィンドウ") { entry($0.name, .app(bundleID: $0.bundleID, name: $0.name)) }
        }
    }

    /// エージェントへ渡す、まとめ方（発話の区切り／会話の区切り／まとまってから解説／約 30 秒／約 5 秒）。
    private func batchModeItem() -> NSMenuItem {
        submenuItem("転送のまとめ方: " + controller.batchMode.title) { submenu in
            for mode in BatchMode.allCases {
                submenu.addItem(choice(mode.title, selected: mode == controller.batchMode) { [controller] in controller.setBatchMode(mode) })
            }
        }
    }

    /// 分析のしかた：プリセット（解説・提案・サマリーの出し方）。同梱のものと、自分のフォルダのもの。
    private func presetItem() -> NSMenuItem {
        let selected = controller.presetStore.resolve(id: controller.presetID)?.id
        return submenuItem("分析のプリセット: " + controller.presetName) { submenu in
            for preset in controller.presets() {
                let title = preset.name + (preset.source == .user ? "（自分）" : "")
                submenu.addItem(choice(title, selected: preset.id == selected, tooltip: preset.summary.isEmpty ? nil : preset.summary) { [controller] in controller.setPreset(preset.id) })
            }
            submenu.addItem(.separator())
            submenu.addItem(action("プリセットのフォルダを開く（自分のものを足す）", #selector(openPresetFolder)))
        }
    }

    @objc private func openPresetFolder() { controller.openPresetFolder() }

    /// マイク（本人）のオン／オフ。
    private func microphoneItem() -> NSMenuItem {
        let item = action("マイク", #selector(toggleMicrophone))
        item.state = controller.selection.microphone ? .on : .off
        return item
    }

    @objc private func toggleMicrophone() { controller.setMicrophone(!controller.selection.microphone) }

    /// システム音声（相手）の選択：オフ・全体・起動中のアプリ。
    private func systemItem() -> NSMenuItem {
        let current = controller.selection.system
        let title: String
        switch current {
        case .off: title = "オフ"
        case .all: title = "全体"
        case .app(_, let name): title = name
        }
        return submenuItem("システム音声: " + title) { submenu in
            submenu.addItem(choice("オフ", selected: current == .off) { [controller] in controller.setSystem(.off) })
            submenu.addItem(choice("全体（Mac から出ている音すべて）", selected: current == .all) { [controller] in controller.setSystem(.all) })
            addApps(to: submenu, heading: "アプリを選ぶ") { app in
                var selected = false
                if case .app(let id, _) = current, id == app.bundleID { selected = true }
                return choice(app.name, selected: selected) { [controller] in controller.setSystem(.app(bundleID: app.bundleID, name: app.name)) }
            }
        }
    }

    @objc private func start() { controller.start() }
    @objc private func pause() { controller.pause() }
    @objc private func resume() { controller.resume() }
    @objc private func endMeeting() { controller.endFromMenu() }
}
