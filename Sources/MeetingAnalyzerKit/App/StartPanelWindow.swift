import AppKit
import SwiftUI

/// 「設定して開始…」（SPEC §3.1・§4）：取り込み（マイク・システム音声・画面）と、転送（まとめ方・分析のプリセット）を、その場で選んでから、開始する。
/// 選んだ内容は、設定ウィンドウと同じ設定へ保存される（次の会議にも、そのまま使われる）。開始のたびの確認のダイアログではなく、**利用者が選んだときだけ**出す。
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
            window.title = "設定して開始"
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

/// 「設定して開始」の表示用の状態。コントローラーの変化で、表示を更新する。起動中のアプリの一覧は、開くたびに読み直す。
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
                CaptureChoicesView(controller: controller, apps: model.apps)
                ForwardingChoicesView(controller: controller)
                ActorChoicesView(controller: controller)
                Section {
                    Text("ここで選んだ内容は、設定にも保存され、次の会議にも使われます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
        .frame(width: 540, height: 720)
    }
}
