import SwiftUI

/// 起動中のアプリの選択肢 1 つ。
struct AppChoice {
    let bundleID: String
    let name: String
    let title: String
}

/// 取り込み・転送の選択の、共通の部品（設定ウィンドウと、開始の前の設定の画面が、同じものを使う）。
enum CaptureChoices {
    /// 起動中のアプリの選択肢。いま選んでいるアプリが、起動していなければ、「起動していません」として加える（選択を失わない）。
    static func appChoices(apps: [CaptureApp], current: SystemSource) -> [AppChoice] {
        var choices = apps.map { AppChoice(bundleID: $0.bundleID, name: $0.name, title: $0.name) }
        if case .app(let id, let name) = current, !choices.contains(where: { $0.bundleID == id }) {
            choices.insert(AppChoice(bundleID: id, name: name, title: "\(name)（起動していません）"), at: 0)
        }
        return choices
    }

    static func screenApp(_ selection: ScreenSelection) -> SystemSource {
        if case .app(let id, let name) = selection { return .app(bundleID: id, name: name) }
        return .off
    }
}

/// 取り込む音声（マイク・システム音声）と、画面の選択。
struct CaptureChoicesView: View {
    let controller: MeetingController
    /// 画面の更新の合図（呼び出し側の `revision`）。`controller` は参照で、変わらないので、これが無いと、SwiftUI が、この部品の本文を作り直さず、選んだ内容が、画面に出ない。
    let revision: Int
    let apps: [CaptureApp]

    var body: some View {
        Section("取り込む音声") {
            Toggle("マイク（本人）", isOn: Binding(get: { controller.selection.microphone }, set: { controller.setMicrophone($0) }))
            Picker("システム音声（相手）", selection: Binding(get: { controller.selection.system }, set: { controller.setSystem($0) })) {
                Text("オフ").tag(SystemSource.off)
                Text("全体（Mac から出ている音すべて）").tag(SystemSource.all)
                Divider()
                ForEach(CaptureChoices.appChoices(apps: apps, current: controller.selection.system), id: \.bundleID) { app in
                    Text(app.title).tag(SystemSource.app(bundleID: app.bundleID, name: app.name))
                }
            }
        }

        Section("画面") {
            Picker("画面の取り込み", selection: Binding(get: { controller.screen }, set: { controller.setScreen($0) })) {
                Text("オフ").tag(ScreenSelection.off)
                Text("画面全体（メインの画面）").tag(ScreenSelection.display)
                Divider()
                ForEach(CaptureChoices.appChoices(apps: apps, current: CaptureChoices.screenApp(controller.screen)), id: \.bundleID) { app in
                    Text(app.title).tag(ScreenSelection.app(bundleID: app.bundleID, name: app.name))
                }
            }
            Text("オフ以外では、画面に変化があったときだけ、縮小した画像を字幕に添えて渡し、記録にも入れます（画面収録の許可が要ります）。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// エージェントへの転送の選択（転送のまとめ方・分析のプリセット）。
struct ForwardingChoicesView: View {
    let controller: MeetingController
    /// 画面の更新の合図（`CaptureChoicesView.revision` と同じ理由）。
    let revision: Int
    /// 設定ウィンドウでは、自分のプリセットを足すフォルダを開くボタンも出す。
    var showsFolderButton = false

    private var currentPresetID: String { controller.presetStore.resolve(id: controller.presetID)?.id ?? AnalysisPreset.defaultID }

    var body: some View {
        Section("エージェントへの転送") {
            Picker("転送のまとめ方", selection: Binding(get: { controller.batchMode }, set: { controller.setBatchMode($0) })) {
                ForEach(BatchMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }
            Picker("分析のプリセット", selection: Binding(get: { currentPresetID }, set: { controller.setPreset($0) })) {
                ForEach(controller.presets(), id: \.id) { preset in
                    Text(preset.name + (preset.source == .user ? "（自分）" : "")).tag(preset.id)
                }
            }
            if showsFolderButton { Button("プリセットのフォルダを開く（自分のものを足す）") { controller.openPresetFolder() } }
        }
    }
}

/// アクター定義（ACTOR.md）の選択と、今日の出席者（開始の前の設定の画面で使う。設定ウィンドウは、同じ操作を、自分のページに持つ）。
struct ActorChoicesView: View {
    let controller: MeetingController
    /// 画面の更新の合図（`CaptureChoicesView.revision` と同じ理由）。
    let revision: Int

    /// 選べるファイル：最近使ったもの（いまも存在するもの）と、いま選んでいるもの。
    private var files: [String] {
        var paths = controller.actorFiles.filter { FileManager.default.fileExists(atPath: $0) }
        if let current = controller.actorFile, !paths.contains(current) { paths.insert(current, at: 0) }
        return paths
    }

    /// 「親のフォルダ名/ファイル名」（ACTOR.md は、プロジェクトごとにあるので、フォルダ名で区別する）。
    static func shortName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
    }

    var body: some View {
        Section("アクター定義（ACTOR.md）") {
            Picker("ACTOR.md", selection: Binding<String?>(get: { controller.actorFile }, set: { controller.setActorFile($0) })) {
                Text("使わない").tag(String?.none)
                ForEach(files, id: \.self) { path in Text(Self.shortName(path)).tag(String?.some(path)) }
            }
            Button("別のファイルを選ぶ…") { if let path = ActorFilePicker.choose() { controller.setActorFile(path) } }
            switch controller.actorStatus {
            case .none:
                Text("選ぶと、記録と転送に、本人・相手の名前を入れます。").font(.caption).foregroundStyle(.secondary)
            case .failed(let reason):
                Text(reason).font(.caption).foregroundStyle(.red)
            case .loaded(let count, let hasSelf, let warnings):
                Text("\(count) 人を読み込みました" + (hasSelf ? "" : "（「本人: はい」の人がいないので、マイクの発話は「本人」のままです）")).font(.caption).foregroundStyle(.secondary)
                ForEach(warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }
            let choices = controller.actorChoices
            if !choices.isEmpty {
                Text("今日の出席者（相手の側。チェックした人から、話者を判断します）").font(.caption).foregroundStyle(.secondary)
                ForEach(choices, id: \.name) { choice in
                    Toggle(choice.role.map { "\(choice.name)（\($0)）" } ?? choice.name, isOn: Binding(get: { choice.present }, set: { controller.setPresent(choice.name, $0) }))
                }
            }
        }
    }
}
