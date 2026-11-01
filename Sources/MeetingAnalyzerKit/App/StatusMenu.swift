import AppKit

/// メニューバーの項目。メニューは、開くたびに、会議の状態から作り直す（会議が実行中でないとき、何も動かさない）。
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let controller: MeetingController
    private lazy var settings = SettingsWindow(controller: controller)
    private lazy var startPanel = StartPanelWindow(controller: controller)
    private lazy var naming = SpeakerNamingWindow(controller: controller)

    init(controller: MeetingController) {
        self.controller = controller
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        controller.observe { [weak self] in self?.refreshIcon() }
        controller.onNamingAvailable = { [weak self] in self?.naming.show() }
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

        // 待機中は、いま選んでいる取り込み（読むだけ。変えるのは、設定ウィンドウ）。
        if controller.state == .idle {
            let screen = controller.screen == .off ? "" : " ／ 画面: \(controller.screen.title)"
            let model = controller.transcription == .apple ? "" : " ／ モデル: \(controller.transcription.title)"
            menu.addItem(label("取り込み: \(controller.selection.summary)\(screen)\(model)"))
        }
        menu.addItem(.separator())

        // 会議の操作（開始・一時停止・再開・終了）。
        switch controller.state {
        case .idle:
            // 「開始」を選ぶと、毎回、開始の前の設定の画面（取り込み・転送・アクター定義・話者の人数）が出て、そこで「開始」を押すと始まる（SPEC §4）。
            menu.addItem(action("開始…", #selector(openStartPanel)))
            // 直前の会議に、名前を付けていない話者がいる・分け直せるとき、または、音声を保存した過去の会議があるとき（SPEC §3.15・§3.16）。
            if controller.canOpenNaming { menu.addItem(action("話者の名付け…", #selector(openNaming))) }
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

        // 話者（アクター）：出席者（会議の途中でも変えられる）。使う ACTOR.md の選択は、開始の前の設定の画面と、設定ウィンドウ。
        let choices = controller.actorChoices
        if !choices.isEmpty {
            menu.addItem(attendeesItem(choices))
            menu.addItem(.separator())
        }

        // 設定ウィンドウ（取り込み・まとめ方・プリセット・保持期間）と、アプリの操作（コマンド・フォルダ）。
        menu.addItem(action("設定…", #selector(openSettings), key: ","))
        menu.addItem(commandItem())
        menu.addItem(action("MeetingAnalyzer のフォルダを開く（記録・画像・プリセット）", #selector(openDataFolder)))
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

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    /// 出席者の選択（相手の側の人。チェックした人から、話者を判断する）。**会議の途中でも、押せる**（次の判断から効く）。
    private func attendeesItem(_ choices: [ActorSelection.Choice]) -> NSMenuItem {
        let item = NSMenuItem(title: "出席者（\(choices.filter(\.present).count)/\(choices.count) 人）", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(label("チェックした人から、相手の話者を判断します"))
        for choice in choices {
            let child = NSMenuItem(title: choice.role.map { "\(choice.name)（\($0)）" } ?? choice.name, action: #selector(toggleAttendee(_:)), keyEquivalent: "")
            child.target = self
            child.state = choice.present ? .on : .off
            child.representedObject = choice.name
            submenu.addItem(child)
        }
        item.submenu = submenu
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

    @objc private func openDataFolder() { controller.openDataFolder() }

    @objc private func openSettings() { settings.show() }

    @objc private func toggleAttendee(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        controller.setPresent(name, sender.state != .on)
    }

    // MARK: 会議の操作

    @objc private func openStartPanel() { startPanel.show() }
    @objc private func pause() { controller.pause() }
    @objc private func resume() { controller.resume() }
    @objc private func endMeeting() { controller.endFromMenu() }
}

extension StatusMenu {
    @objc fileprivate func openNaming() { naming.show() }
}
