import AppKit
import SwiftUI

/// 設定ウィンドウ（SPEC §3.1・§5）。マイク・システム音声・画面の取り込み・転送のまとめ方・分析のプリセット・記録の保持期間を、メニューを開き直さずに、続けて選べる。
/// 選択は、`MeetingController` が覚える。会議の実行中は、取り込みの設定を変えられない（保持期間は、いつでも変えられる）。
@MainActor
final class SettingsWindow {
    private let controller: MeetingController
    private var window: NSWindow?

    init(controller: MeetingController) {
        self.controller = controller
    }

    /// ウィンドウを前面に出す（無ければ作る。閉じても、アプリは終了しない）。
    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: SettingsModel(controller: controller)))
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(AppInfo.name) の設定"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// 設定ウィンドウの表示用の状態。コントローラーの変化と、起動中のアプリの増減で、表示を更新する。
@MainActor
final class SettingsModel: ObservableObject {
    let controller: MeetingController
    /// システム音声・画面に選べる、起動中のアプリ。
    @Published private(set) var apps: [CaptureApp] = []
    /// 変わるたびに増やし、表示を作り直させる。
    @Published private(set) var revision = 0
    private var tokens: [NSObjectProtocol] = []

    init(controller: MeetingController) {
        self.controller = controller
        apps = controller.candidateApps()
        controller.observe { [weak self] in self?.revision += 1 }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshApps() }
            })
        }
    }

    deinit {
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    func refreshApps() {
        apps = controller.candidateApps()
        revision += 1
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private var controller: MeetingController { model.controller }
    /// 会議の実行中・一時停止中・処理中は、取り込みの設定を変えられない。
    private var locked: Bool { controller.state != .idle }

    var body: some View {
        // `revision` を読んで、コントローラーの変化のたびに、表示を作り直す。
        let _ = model.revision
        Form {
            if locked {
                Section {
                    Label("会議の途中は、取り込みの設定を変えられません。会議を終了してから変えてください。", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
            }
            Section("取り込む音声") {
                Toggle("マイク（本人）", isOn: Binding(get: { controller.selection.microphone }, set: { controller.setMicrophone($0) }))
                Picker("システム音声（相手）", selection: Binding(get: { controller.selection.system }, set: { controller.setSystem($0) })) {
                    Text("オフ").tag(SystemSource.off)
                    Text("全体（Mac から出ている音すべて）").tag(SystemSource.all)
                    Divider()
                    ForEach(appChoices(current: controller.selection.system), id: \.bundleID) { app in
                        Text(app.title).tag(SystemSource.app(bundleID: app.bundleID, name: app.name))
                    }
                }
            }
            .disabled(locked)

            Section("画面") {
                Picker("画面の取り込み", selection: Binding(get: { controller.screen }, set: { controller.setScreen($0) })) {
                    Text("オフ").tag(ScreenSelection.off)
                    Text("画面全体（メインの画面）").tag(ScreenSelection.display)
                    Divider()
                    ForEach(appChoices(current: screenApp(controller.screen)), id: \.bundleID) { app in
                        Text(app.title + "のウィンドウ").tag(ScreenSelection.app(bundleID: app.bundleID, name: app.name))
                    }
                }
                Text("オフ以外では、画面に変化があったときだけ、縮小した画像を字幕に添えて渡し、記録にも入れます（画面収録の許可が要ります）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(locked)

            Section("エージェントへの転送") {
                Picker("転送のまとめ方", selection: Binding(get: { controller.batchMode }, set: { controller.setBatchMode($0) })) {
                    ForEach(BatchMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                Picker("分析のプリセット", selection: Binding(get: { currentPresetID }, set: { controller.setPreset($0) })) {
                    ForEach(controller.presets(), id: \.id) { preset in
                        Text(preset.name + (preset.source == .user ? "（自分）" : "")).tag(preset.id)
                    }
                }
                Button("プリセットのフォルダを開く（自分のものを足す）") { controller.openPresetFolder() }
            }
            .disabled(locked)

            Section("記録") {
                Picker("記録の保持期間", selection: Binding(get: { controller.retentionDays }, set: { controller.setRetentionDays($0) })) {
                    ForEach(RecordRetentionSetting.choices, id: \.self) { days in Text(RecordRetentionSetting.title(days)).tag(days) }
                }
                Text("期限を過ぎると、文字起こしも画像も、フォルダごと消えます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var currentPresetID: String { controller.presetStore.resolve(id: controller.presetID)?.id ?? AnalysisPreset.defaultID }

    private func screenApp(_ selection: ScreenSelection) -> SystemSource {
        if case .app(let id, let name) = selection { return .app(bundleID: id, name: name) }
        return .off
    }

    /// 起動中のアプリの選択肢。いま選んでいるアプリが、起動していなければ、「起動していません」として加える（選択を失わない）。
    private func appChoices(current: SystemSource) -> [AppChoice] {
        var choices = model.apps.map { AppChoice(bundleID: $0.bundleID, name: $0.name, title: $0.name) }
        if case .app(let id, let name) = current, !choices.contains(where: { $0.bundleID == id }) {
            choices.insert(AppChoice(bundleID: id, name: name, title: "\(name)（起動していません）"), at: 0)
        }
        return choices
    }
}

private struct AppChoice {
    let bundleID: String
    let name: String
    let title: String
}
