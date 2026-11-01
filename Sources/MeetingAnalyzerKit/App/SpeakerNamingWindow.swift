import AppKit
import SwiftUI

/// 話者の名付けのウィンドウ（SPEC §3.15）。直前の会議の、声で分けた話者（話者 N）ごとに、発言の抜粋を見ながら、名前を確定する。
/// 確定は、人間が押したときだけ（自動では確定しない）。確定すると、記録を書き直し、エージェントへ知らせる。
@MainActor
final class SpeakerNamingWindow {
    private let controller: MeetingController
    private var window: NSWindow?

    init(controller: MeetingController) {
        self.controller = controller
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SpeakerNamingView(model: SpeakerNamingModel(controller: controller)))
            let window = NSWindow(contentViewController: hosting)
            window.title = "話者の名付け"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Task { await controller.computeNamingHints() }
    }
}

/// 名付けの画面の表示用の状態。入力中の名前（確定前）と、確定の失敗の文を持つ。
@MainActor
final class SpeakerNamingModel: ObservableObject {
    let controller: MeetingController
    @Published private(set) var revision = 0
    /// 話者 N → 入力中の名前（確定前）。
    @Published var drafts: [Int: String] = [:]
    /// 話者 N → 確定に失敗した理由。
    @Published private(set) var failures: [Int: String] = [:]
    /// 話者 N → 確定はしたが、声を覚えられなかった理由。
    @Published private(set) var warnings: [Int: String] = [:]
    /// 話者 N → 「この声を覚える」（既定はオン。声紋を使うときだけ見せる）。
    @Published var remember: [Int: Bool] = [:]
    /// 確定の処理中の話者。
    @Published private(set) var working: Set<Int> = []

    init(controller: MeetingController) {
        self.controller = controller
        controller.observe { [weak self] in self?.revision += 1 }
    }

    func confirm(_ id: Int) {
        guard !working.contains(id) else { return }
        working.insert(id)
        failures[id] = nil
        let name = drafts[id] ?? ""
        let remember = self.remember[id] ?? true
        Task {
            let outcome = await controller.confirmSpeakerName(id, name: name, remember: remember)
            working.remove(id)
            failures[id] = outcome.failure
            warnings[id] = outcome.warning
            if outcome.failure == nil { drafts[id] = nil }
        }
    }
}

struct SpeakerNamingView: View {
    @ObservedObject var model: SpeakerNamingModel

    private var controller: MeetingController { model.controller }

    var body: some View {
        let _ = model.revision
        VStack(alignment: .leading, spacing: 12) {
            if controller.namingSession == nil {
                Text("名前を付けられる会議がありません。会議が終わったあと、次の会議を始めるまでの間だけ、付けられます。")
                    .foregroundStyle(.secondary)
            } else {
                Text("声で分けた話者に、名前を付けます。「確定」を押した話者だけが、記録に反映されます（自動では確定しません）。確定した名前は、変えられません。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                switch controller.hintState {
                case .computing: Label("名前のヒントを計算中…（名付けは、そのまま、できます）", systemImage: "hourglass").font(.callout).foregroundStyle(.secondary)
                case .failed(let reason): Label(reason, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                case .notRequested, .ready: EmptyView()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(controller.namingSpeakers, id: \.id) { speaker in
                            row(speaker)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    private func row(_ speaker: SpeakerSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("話者 \(speaker.id)").font(.headline)
                Text("\(Self.duration(speaker.seconds))・\(speaker.utteranceCount) 発言").foregroundStyle(.secondary)
            }
            ForEach(Array(speaker.excerpts.enumerated()), id: \.offset) { _, excerpt in
                Text("「\(excerpt)」").font(.callout).foregroundStyle(.secondary)
            }
            if let name = controller.namedSpeakers[speaker.id] {
                if controller.voiceMatched.contains(speaker.id) {
                    Label("声紋で一致: \(name)", systemImage: "waveform.badge.checkmark").foregroundStyle(.green)
                } else {
                    Label("確定: \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if let warning = model.warnings[speaker.id] {
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
            } else {
                if let candidates = controller.namingCandidates[speaker.id], !candidates.isEmpty {
                    HStack {
                        Text("声紋の候補:").font(.callout).foregroundStyle(.secondary)
                        ForEach(candidates, id: \.name) { candidate in
                            Button("\(candidate.name)（類似度 \(String(format: "%.2f", candidate.similarity))）") { model.drafts[speaker.id] = candidate.name }
                        }
                    }
                }
                if let hints = controller.namingHints[speaker.id], !hints.isEmpty {
                    HStack {
                        Text("名前のヒント（確定ではありません）:").font(.callout).foregroundStyle(.secondary)
                        ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                            Button(Self.hintTitle(hint)) { model.drafts[speaker.id] = hint.name }
                        }
                    }
                }
                HStack {
                    TextField("名前", text: Binding(get: { model.drafts[speaker.id] ?? "" }, set: { model.drafts[speaker.id] = $0 }))
                        .onSubmit { model.confirm(speaker.id) }
                    if !controller.nameCandidates.isEmpty {
                        Menu("出席者から選ぶ") {
                            ForEach(controller.nameCandidates, id: \.self) { name in
                                Button(name) { model.drafts[speaker.id] = name }
                            }
                        }
                        .fixedSize()
                    }
                    Button("確定") { model.confirm(speaker.id) }
                        .disabled(model.working.contains(speaker.id) || (model.drafts[speaker.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if controller.voiceprintsEnabled {
                    Toggle("この声を覚える（次の会議から、同じ声の人に、この名前を付ける）", isOn: Binding(get: { model.remember[speaker.id] ?? true }, set: { model.remember[speaker.id] = $0 }))
                        .font(.callout)
                }
                if let failure = model.failures[speaker.id] {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                }
            }
        }
    }

    /// 「12 分 3 秒」（1 分未満は「45 秒」）。
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 60 ? "\(total / 60) 分 \(total % 60) 秒" : "\(total) 秒"
    }
}

extension SpeakerNamingView {
    /// ヒントのボタンの文：「名乗りあり: 佐藤 花子」・「佐藤 花子 62%」。
    static func hintTitle(_ hint: SpeakerHint) -> String {
        if hint.introduced { return "名乗りあり: \(hint.name)" }
        return "\(hint.name) \(Int(((hint.probability ?? 0) * 100).rounded()))%"
    }
}
