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
    /// 削除の確認を出しているモデルの ID（`@State` のマクロは、Command Line Tools だけの環境で使えないため、ここに持つ）。
    @Published var confirmingDelete: String?
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
            Section("文字起こし") {
                Picker("使うモデル", selection: Binding(get: { controller.transcription }, set: { controller.setTranscription($0) })) {
                    Text("Mac 標準").tag(TranscriptionChoice.apple)
                    ForEach(LocalModelCatalog.all.filter { controller.isInstalled($0) }) { model in
                        Text(model.name).tag(TranscriptionChoice.local(model.id))
                    }
                }
                .disabled(locked)
                Text(controller.transcription == .apple
                     ? "Mac の音声認識（オンデバイス）。話している途中から、暫定の文字が出ます。"
                     : "ダウンロードしたモデル（オンデバイス）。話し終わって、少し間があってから、文字になります（暫定の文字は出ません）。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("追加でダウンロードするモデル") {
                ForEach(LocalModelCatalog.all) { entry in
                    ModelRow(settings: model, model: entry, locked: locked)
                }
                Text("ダウンロードは、ここで押したときだけ、Hugging Face から行います（音声は送りません）。途中で止めても、続きから取得できます。")
                    .font(.caption).foregroundStyle(.secondary)
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
                        Text(app.title).tag(ScreenSelection.app(bundleID: app.bundleID, name: app.name))
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

/// 追加でダウンロードするモデル 1 つ：名前・説明・大きさと、取得（進み具合・取消）・削除。
private struct ModelRow: View {
    @ObservedObject var settings: SettingsModel
    let model: LocalModel
    /// 会議の実行中（使っているモデルは、消せない）。
    let locked: Bool

    private var controller: MeetingController { settings.controller }
    private var confirmDelete: Binding<Bool> {
        Binding(get: { settings.confirmingDelete == model.id }, set: { settings.confirmingDelete = $0 ? model.id : nil })
    }

    private var installed: Bool { controller.isInstalled(model) }
    private var downloading: MeetingController.ModelDownload? { controller.download?.id == model.id ? controller.download : nil }
    private var inUse: Bool { controller.transcription == .local(model.id) }
    private var partial: Bool { !installed && controller.modelStore.downloadedBytes(model.artifact) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(model.name)
                        Text(Self.size(model.artifact.bytes)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                control
            }
            if let downloading {
                ProgressView(value: Double(downloading.received), total: Double(max(1, downloading.total)))
                Text("\(Self.size(downloading.received)) / \(Self.size(downloading.total))").font(.caption).foregroundStyle(.secondary)
            }
            if let failure = controller.downloadFailure, failure.id == model.id {
                Text(failure.reason).font(.caption).foregroundStyle(.red)
            }
        }
        .confirmationDialog("「\(model.name)」を削除しますか？", isPresented: confirmDelete) {
            Button("削除", role: .destructive) { controller.deleteModel(model) }
        } message: {
            Text(inUse ? "使っているモデルです。削除すると、Mac 標準に戻ります。もう一度使うには、ダウンロードし直します。" : "もう一度使うには、ダウンロードし直します。")
        }
    }

    @ViewBuilder private var control: some View {
        if downloading != nil {
            Button("取り消す") { controller.cancelDownload() }
        } else if installed {
            Button("削除…", role: .destructive) { settings.confirmingDelete = model.id }
                .disabled(inUse && locked)
        } else {
            Button(partial ? "続きから取得" : "ダウンロード") { controller.downloadModel(model) }
                .disabled(controller.download != nil)
        }
    }

    private static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : "\(bytes / 1_000_000) MB"
    }
}
