import AppKit
import SwiftUI

/// 開始の前の設定の画面（SPEC §4）：「開始」を選ぶたびに出る。取り込み（マイク・システム音声・画面）・（声の分離がオンなら）話者の人数・転送（まとめ方・分析のプリセット）・アクター定義（ACTOR.md・出席者）を、その場で選んで、「開始」を押すと始まる。
/// 選んだ内容は、設定ウィンドウと同じ設定へ保存される（次の会議にも、そのまま使われる）。
@MainActor
final class StartPanelWindow {
    private let controller: MeetingController
    private var window: NSWindow?
    private var model: StartPanelModel?

    init(controller: MeetingController) {
        self.controller = controller
    }

    func show() {
        if window == nil {
            let model = StartPanelModel(controller: controller)
            model.onStart = { [weak self] in self?.window?.orderOut(nil) }
            model.onCancel = { [weak self] in self?.window?.orderOut(nil) }
            let window = NSWindow(contentViewController: NSHostingController(rootView: StartPanelView(model: model)))
            window.title = "開始の設定"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
            self.model = model
        }
        model?.refreshApps()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// 開始の前の設定の表示用の状態。コントローラーの変化で、表示を更新する。起動中のアプリの一覧は、開くたびに読み直す。
@MainActor
final class StartPanelModel: ObservableObject {
    let controller: MeetingController
    @Published private(set) var revision = 0
    @Published private(set) var apps: [CaptureApp] = []
    var onStart: () -> Void = {}
    var onCancel: () -> Void = {}

    init(controller: MeetingController) {
        self.controller = controller
        apps = controller.candidateApps()
        controller.observe { [weak self] in self?.revision += 1 }
    }

    func refreshApps() {
        apps = controller.candidateApps()
        revision += 1
    }

    func start() {
        controller.start()
        onStart()
    }
}

struct StartPanelView: View {
    @ObservedObject var model: StartPanelModel

    private var controller: MeetingController { model.controller }
    private var idle: Bool { controller.state == .idle }

    var body: some View {
        let _ = model.revision
        VStack(spacing: 0) {
            Form {
                if !idle {
                    Section { Label("会議の実行中は、選べません。", systemImage: "lock").foregroundStyle(.secondary) }
                }
                Section("会議の題名（任意）") {
                    TextField("会議の題名", text: titleBinding, prompt: Text("例：週次の定例（空なら、自動で付けます）"))
                        .labelsHidden()
                    Text("記録の見出しと、エージェントへの開始の出来事に入ります。あとから名付けるとき、会議を見分けやすくなります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CaptureChoicesView(controller: controller, revision: model.revision, apps: model.apps)
                StartVoiceSection(controller: controller, revision: model.revision)
                ForwardingChoicesView(controller: controller, revision: model.revision)
                ActorChoicesView(controller: controller, revision: model.revision)
                StartStatusSection(controller: controller, revision: model.revision)
            }
            .formStyle(.grouped)
            .disabled(!idle)
            Divider()
            HStack {
                if controller.selection.isEmpty {
                    Label("取り込む音声（マイクかシステム音声）を選んでください", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                Spacer()
                Button("キャンセル") { model.onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("開始") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!idle || controller.selection.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 540, height: 760)
    }

    private var titleBinding: Binding<String> {
        Binding<String>(get: { controller.meetingTitle }, set: { controller.setMeetingTitle($0) })
    }
}

/// 開始の前の、接続と許可の状況（読むだけ）。許可は、確認だけで、要求しない（要求は、開始のときに OS が行う）。
struct StartStatusSection: View {
    let controller: MeetingController
    /// 画面の更新の合図（`CaptureChoicesView.revision` と同じ理由）。
    let revision: Int

    var body: some View {
        Section("状況") {
            row(controller.agentCount > 0, ok: "エージェント: \(controller.agentCount) 件接続中", ng: "エージェント: 未接続（字幕を渡す先が、まだありません）")
            if controller.selection.microphone {
                row(MicrophoneCapture.isAuthorized, ok: "マイクの許可: 済み", ng: "マイクの許可: まだ（開始のとき、OS が確認します。断ると、取り込めません）")
            }
            if controller.selection.system != .off || controller.screen != .off {
                row(ScreenRecordingPermission.isGranted, ok: "画面収録の許可: 済み", ng: "画面収録の許可: まだ（システム音声・画面の取り込みに要ります。開始のとき、OS が確認します）")
            }
            Text("ここで選んだ内容は、設定にも保存され、次の会議にも使われます（題名は、その会議だけ）。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 1 行（できていれば緑のチェック、まだなら、橙の注意）。
    @ViewBuilder private func row(_ ok: Bool, ok okText: String, ng ngText: String) -> some View {
        if ok {
            Label(okText, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        } else {
            Label(ngText, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
        }
    }
}

/// 開始の前の、話者の分離（声）の選択。声の分離のオン／オフ（モデルが取得済みのときだけ）・話者の人数・相手の音声の保存・声紋を使う。モデルの取得・削除と、分離の調整（詳細）は、設定ウィンドウ。
struct StartVoiceSection: View {
    let controller: MeetingController
    /// 画面の更新の合図（`CaptureChoicesView.revision` と同じ理由）。
    let revision: Int

    private static let speakerCounts: [Int] = Array(VoiceSeparationTuning.speakerCountRange)

    private var speakerCountBinding: Binding<Int> {
        Binding<Int>(get: { controller.voiceSpeakerCount ?? 0 }, set: { controller.setVoiceSpeakerCount($0 == 0 ? nil : $0) })
    }

    var body: some View {
        Section("話者の分離（声）") {
            if let voice = controller.voiceModel {
                Toggle("声の違いで、相手の話者を分ける", isOn: Binding(get: { controller.voiceSeparation }, set: { controller.setVoiceSeparation($0) }))
                    .disabled(!controller.isInstalled(voice))
                if !controller.isInstalled(voice) {
                    Text("分離のモデル（約 22 MB）が、まだ取得されていません。設定ウィンドウの「話者（アクター）」で、ダウンロードしてください。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if controller.voiceSeparation {
                Picker("話者の人数", selection: speakerCountBinding) {
                    Text("自動").tag(0)
                    ForEach(Self.speakerCounts, id: \.self) { count in Text("\(count) 人").tag(count) }
                }
                Text("相手の人数（2〜8）が分かっているときは、指定すると、その数に分けます。声の似た人が 1 つにまとまるときに、効きます。分からなければ、自動のままにします。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("相手の音声を保存する", isOn: Binding(get: { controller.saveOthersAudio }, set: { controller.setSaveOthersAudio($0) }))
                Text("相手の声（システム音声）の録音を、この Mac に、記録と同じ期間だけ保存します。マイク（あなた）の声は保存しません。保存すると、あとから、分け直し・聞き直し・名付けができます。録音は、参加者の声なので、参加者へ知らせてください。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("声紋を使う", isOn: Binding(get: { controller.voiceprintsEnabled }, set: { controller.setVoiceprints($0) }))
                Text("名付けで「この声を覚える」を選んだ人の、声の特徴（音声ではありません）だけを、この Mac に保存し、次の会議で、同じ声の人に、同じ名前を付けます。参加者へ知らせる責任は、利用者にあります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
