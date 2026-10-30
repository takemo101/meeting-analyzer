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
    /// サイドバーで選んでいるページ（`@State` を使えないので、ここに持つ）。
    @Published var page: SettingsPage = .capture
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
        HStack(spacing: 0) {
            List(SettingsPage.allCases, selection: Binding<SettingsPage?>(get: { model.page }, set: { if let page = $0 { model.page = page } })) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            Form {
                if locked, model.page != .record {
                    Section {
                        Label("会議の途中は、取り込みの設定を変えられません。会議を終了してから変えてください。" + (model.page == .actors ? "（出席者は、途中でも変えられます）" : ""), systemImage: "lock")
                            .foregroundStyle(.secondary)
                    }
                }
                switch model.page {
                case .capture: captureSections
                case .transcription: transcriptionSections
                case .actors: actorSections
                case .forwarding: forwardingSections
                case .record: recordSections
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 820, height: 560)
    }

    // MARK: ページ

    @ViewBuilder private var captureSections: some View {
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
    }

    @ViewBuilder private var transcriptionSections: some View {
        Section("使うモデル") {
            Picker("文字起こし", selection: Binding(get: { controller.transcription }, set: { controller.setTranscription($0) })) {
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
                ModelRow(settings: model, spec: ModelRowSpec(entry, controller), locked: locked)
            }
            Text("ダウンロードは、ここで押したときだけ、Hugging Face から行います（音声は送りません）。途中で止めても、続きから取得できます。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actorSections: some View {
        Section("アクター定義") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTOR.md")
                    if let path = controller.actorFile {
                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("選ぶと、記録と転送に、本人・相手の名前を入れます").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if controller.actorFile != nil { Button("外す") { controller.setActorFile(nil) } }
                Button("選ぶ…") { controller.chooseActorFile() }
            }
            actorStatusView
        }
        .disabled(locked)

        Section("相手の話者の推定") {
            Picker("使うモデル", selection: Binding(get: { controller.decisionModel?.id ?? "" }, set: { controller.setDecisionModel(DecisionModelCatalog.model(id: $0)) })) {
                Text("推定しない（相手のまま）").tag("")
                ForEach(DecisionModelCatalog.all.filter { controller.isInstalled($0) }) { entry in Text(entry.name).tag(entry.id) }
            }
            ForEach(DecisionModelCatalog.all) { entry in
                ModelRow(settings: model, spec: ModelRowSpec(entry, controller), locked: locked)
            }
            Text("発言の内容から、誰が話したかを判断します（この Mac の中だけで動作）。選んでいないときは、「相手」のままです。ダウンロードは、押したときだけ（Hugging Face）。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(locked)

        // 出席者は、会議の実行中でも変えられる（ほかの設定のように、ロックしない）。
        let choices = controller.actorChoices
        if !choices.isEmpty {
            Section("出席者（相手として、判断する人）") {
                ForEach(choices, id: \.name) { choice in
                    Toggle(isOn: Binding(get: { choice.present }, set: { controller.setPresent(choice.name, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.name)
                            if let role = choice.role { Text(role).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Text("チェックした人の中から、相手の話者を判断します。会議の途中でも変えられます（変えたあとの発言から効きます）。チェックし忘れた人の発言は、別の人に付くか、付きません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var forwardingSections: some View {
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
    }

    @ViewBuilder private var recordSections: some View {
        Section("記録") {
            Picker("記録の保持期間", selection: Binding(get: { controller.retentionDays }, set: { controller.setRetentionDays($0) })) {
                ForEach(RecordRetentionSetting.choices, id: \.self) { days in Text(RecordRetentionSetting.title(days)).tag(days) }
            }
            Text("期限を過ぎると、文字起こしも画像も、フォルダごと消えます。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actorStatusView: some View {
        switch controller.actorStatus {
        case .none: EmptyView()
        case .failed(let reason): Text(reason).font(.caption).foregroundStyle(.red)
        case .loaded(let count, let hasSelf, let warnings):
            Text("\(count) 人を読み込みました" + (hasSelf ? "" : "（「本人: はい」の人がいないので、マイクの発話は「本人」のままです）")).font(.caption).foregroundStyle(.secondary)
            ForEach(warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        }
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

/// 設定ウィンドウのサイドバーのページ（取り込み・文字起こし・話者・転送・記録）。
enum SettingsPage: CaseIterable, Hashable, Identifiable {
    case capture, transcription, actors, forwarding, record

    var id: Self { self }

    var title: String {
        switch self {
        case .capture: return "取り込み"
        case .transcription: return "文字起こし"
        case .actors: return "話者（アクター）"
        case .forwarding: return "転送"
        case .record: return "記録"
        }
    }

    var symbol: String {
        switch self {
        case .capture: return "mic"
        case .transcription: return "text.bubble"
        case .actors: return "person.2"
        case .forwarding: return "paperplane"
        case .record: return "doc.text"
        }
    }
}

private struct AppChoice {
    let bundleID: String
    let name: String
    let title: String
}

/// 追加でダウンロードするモデル 1 つの、表示と操作（文字起こしのモデルも、話者の推定のモデルも、同じ行で扱う）。
private struct ModelRowSpec {
    let id: String
    let name: String
    let summary: String
    let bytes: Int64
    let installed: Bool
    let downloadedBytes: Int64
    /// いま使っているか（使っているモデルは、会議の実行中は消せない）。
    let inUse: Bool
    /// 削除の確認で見せる説明。
    let deleteNote: String
    let download: () -> Void
    let discard: () -> Void
    let delete: () -> Void

    @MainActor init(_ model: LocalModel, _ controller: MeetingController) {
        id = model.id; name = model.name; summary = model.summary; bytes = model.artifact.bytes
        installed = controller.isInstalled(model)
        downloadedBytes = controller.modelStore.downloadedBytes(model.artifact)
        inUse = controller.transcription == .local(model.id)
        deleteNote = inUse ? "使っているモデルです。削除すると、Mac 標準に戻ります。もう一度使うには、ダウンロードし直します。" : "もう一度使うには、ダウンロードし直します。"
        download = { controller.downloadModel(model) }
        discard = { controller.discardPartialDownload(model) }
        delete = { controller.deleteModel(model) }
    }

    @MainActor init(_ model: DecisionModel, _ controller: MeetingController) {
        id = model.id; name = model.name; summary = model.summary; bytes = model.bytes
        installed = controller.isInstalled(model)
        // 途中かどうかは、重みで見る（トークナイザは、ほかのモデルと共有していて、先に取得済みのことがある）。
        downloadedBytes = controller.modelStore.downloadedBytes(model.weights)
        inUse = controller.decisionModel == model
        deleteNote = inUse ? "使っているモデルです。削除すると、話者の推定をしなくなります（相手は「相手」のまま）。もう一度使うには、ダウンロードし直します。" : "もう一度使うには、ダウンロードし直します。"
        download = { controller.downloadDecisionModel(model) }
        discard = { controller.discardPartialDownload(model) }
        delete = { controller.deleteDecisionModel(model) }
    }
}

/// 追加でダウンロードするモデル 1 つ：名前・説明・大きさと、取得（進み具合・取消）・削除。
private struct ModelRow: View {
    @ObservedObject var settings: SettingsModel
    let spec: ModelRowSpec
    /// 会議の実行中（使っているモデルは、消せない）。
    let locked: Bool

    private var controller: MeetingController { settings.controller }
    private var confirmDelete: Binding<Bool> {
        Binding(get: { settings.confirmingDelete == spec.id }, set: { settings.confirmingDelete = $0 ? spec.id : nil })
    }
    /// 途中までのダウンロードを捨てる確認（削除の確認と区別するため、別の印を使う）。
    private var confirmDiscard: Binding<Bool> {
        Binding(get: { settings.confirmingDelete == "discard:" + spec.id }, set: { settings.confirmingDelete = $0 ? "discard:" + spec.id : nil })
    }

    private var downloading: MeetingController.ModelDownload? { controller.download?.id == spec.id ? controller.download : nil }
    private var partial: Bool { !spec.installed && spec.downloadedBytes > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(spec.name)
                        Text(Self.size(spec.bytes)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(spec.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                control
            }
            if let downloading {
                ProgressView(value: Double(downloading.received), total: Double(max(1, downloading.total)))
                Text("\(Self.size(downloading.received)) / \(Self.size(downloading.total))").font(.caption).foregroundStyle(.secondary)
            }
            if let failure = controller.downloadFailure, failure.id == spec.id {
                Text(failure.reason).font(.caption).foregroundStyle(.red)
            }
        }
        .confirmationDialog("「\(spec.name)」の、途中までのダウンロードを捨てますか？", isPresented: confirmDiscard) {
            Button("捨てる", role: .destructive) { spec.discard() }
        } message: {
            Text("取得済みの分（\(Self.size(spec.downloadedBytes))）が消えます。もう一度使うには、最初からダウンロードします。")
        }
        .confirmationDialog("「\(spec.name)」を削除しますか？", isPresented: confirmDelete) {
            Button("削除", role: .destructive) { spec.delete() }
        } message: {
            Text(spec.deleteNote)
        }
    }

    @ViewBuilder private var control: some View {
        if downloading != nil {
            Button("取り消す") { controller.cancelDownload() }
        } else if spec.installed {
            Button("削除…", role: .destructive) { settings.confirmingDelete = spec.id }
                .disabled(spec.inUse && locked)
        } else {
            HStack {
                if partial {
                    Button("破棄…", role: .destructive) { settings.confirmingDelete = "discard:" + spec.id }
                        .disabled(controller.download != nil)
                }
                Button(partial ? "続きから取得" : "ダウンロード") { spec.download() }
                    .disabled(controller.download != nil)
            }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : "\(bytes / 1_000_000) MB"
    }
}
