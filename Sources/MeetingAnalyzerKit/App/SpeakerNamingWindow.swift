import AppKit
import SwiftUI

/// 話者の名付けのウィンドウ（SPEC §3.15）。直前の会議の、声で分けた話者（話者 N）ごとに、発言の抜粋を見て（音声が保存されていれば、聞き直して）、名前を確定する。
/// 確定は、人間が押したときだけ（自動では確定しない）。確定すると、記録を書き直し、エージェントへ知らせる。
/// 音声が保存されていれば、人数を指定して、分け直せる（SPEC §3.16。その会議の名前は、すべて外れる）。
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
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 700, height: 680))
            window.contentMinSize = NSSize(width: 620, height: 520)
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Task {
            // 直前の会議が無ければ、音声を保存した、いちばん新しい会議を開く（SPEC §3.16「あとからの名付け」）。
            if controller.namingSession == nil, let newest = controller.namingChoices.first { _ = await controller.openNaming(newest.id) }
            await controller.computeNamingHints()
        }
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
    /// 分け直すときの話者の人数（0＝自動）。初めは、設定の人数。
    @Published var reseparateCount: Int
    /// 分け直しの確認を出しているか（確定した名前が、外れるとき）。
    @Published var confirmingReseparate = false
    /// 会議を開けなかった理由（音声・名付けの写しが無い・読めないなど）。
    @Published var openError: String?

    init(controller: MeetingController) {
        self.controller = controller
        reseparateCount = controller.voiceSpeakerCount ?? 0
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

    /// 分け直す。確定した名前が 1 人でもいれば、先に確認を出す（外れるため）。
    func requestReseparate() {
        if controller.namedSpeakers.isEmpty { reseparate() } else { confirmingReseparate = true }
    }

    func reseparate() {
        let count = reseparateCount == 0 ? nil : reseparateCount
        Task {
            await controller.reseparateSpeakers(count: count)
            // 話者 N の対応が変わったので、入力中の名前・結果の表示は、捨てる。
            if case .done = controller.reseparation {
                drafts = [:]
                failures = [:]
                warnings = [:]
                remember = [:]
            }
        }
    }

    /// 名付ける会議を替える（過去の会議は、名付けの写しから戻す）。入力中の名前・結果の表示は、捨てる。
    func open(_ id: UUID) {
        Task {
            openError = await controller.openNaming(id)
            drafts = [:]
            failures = [:]
            warnings = [:]
            remember = [:]
            await controller.computeNamingHints()
        }
    }
}

struct SpeakerNamingView: View {
    @ObservedObject var model: SpeakerNamingModel

    private var controller: MeetingController { model.controller }

    private static let palette: [Color] = [.blue, .orange, .purple, .teal, .pink, .indigo, .green, .brown]

    var body: some View {
        let _ = model.revision
        Group {
            if controller.namingSession == nil {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            reseparationPanel
                            hintStatus
                            if controller.namingSpeakers.isEmpty {
                                Text("声で分けた話者は、まだいません。上の「分け直す」で、人数を指定して、分け直せます。")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            ForEach(controller.namingSpeakers, id: \.id) { speaker in
                                card(speaker)
                            }
                        }
                        .padding(20)
                    }
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 680)
    }

    // MARK: 上の部分

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("名前を付けられる会議がありません").font(.headline)
            Text("会議が終わったあと、次の会議を始める（またはアプリを終了する）までの間は、付けられます。「相手の音声を保存する」をオンにした会議は、保持期間の間、あとからも付けられます。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !controller.namingChoices.isEmpty { meetingBar }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 名付ける会議の選び（直前の会議・音声を保存した過去の会議）。
    @ViewBuilder private var meetingBar: some View {
        let choices = controller.namingChoices
        let current = controller.namingMeeting
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                if choices.count > 1 || current == nil {
                    Menu {
                        ForEach(choices) { choice in
                            Button { model.open(choice.id) } label: {
                                if choice.id == current?.sessionId { Label(Self.choiceTitle(choice), systemImage: "checkmark") } else { Text(Self.choiceTitle(choice)) }
                            }
                        }
                    } label: {
                        Text(current.map { Self.meetingTitle($0) } ?? "会議を選ぶ")
                    }
                    .fixedSize()
                } else if let current {
                    Text(Self.meetingTitle(current))
                }
            }
            if let error = model.openError { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
        }
    }

    private var header: some View {
        let total = controller.namingSpeakers.count
        let done = controller.namingSpeakers.filter { controller.namedSpeakers[$0.id] != nil }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("話者の名付け").font(.title2.bold())
                Spacer()
                if total > 0 {
                    Label("\(done) / \(total) 人を確定", systemImage: done == total ? "checkmark.circle.fill" : "person.2")
                        .font(.callout).foregroundStyle(done == total ? Color.green : Color.secondary)
                }
            }
            meetingBar
            Text("声で分けた話者ごとに、発言を確かめて、名前を付けます。**「確定」を押した話者だけ**が、記録に反映されます。確定した名前は、変えられません。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    @ViewBuilder private var hintStatus: some View {
        switch controller.hintState {
        case .computing: Label("名前のヒントを計算しています…（名付けは、そのまま、できます）", systemImage: "hourglass").font(.callout).foregroundStyle(.secondary)
        case .failed(let reason): Label(reason, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
        case .notRequested, .ready: EmptyView()
        }
    }

    // MARK: 分け直し

    @ViewBuilder private var reseparationPanel: some View {
        if controller.namingAudioAvailable {
            VStack(alignment: .leading, spacing: 8) {
                Label("人数が合わないときは、分け直す", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                Text("保存した音声で、声の分離をやり直します。**付けた名前は、すべて外れます**（話者の番号が変わるため）。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker("話者の人数", selection: $model.reseparateCount) {
                        Text("自動").tag(0)
                        ForEach(Array(VoiceSeparationTuning.speakerCountRange), id: \.self) { count in Text("\(count) 人").tag(count) }
                    }
                    .fixedSize()
                    .disabled(controller.reseparation == .running)
                    Button("分け直す") { model.requestReseparate() }
                        .disabled(!controller.canReseparate)
                    if controller.reseparation == .running {
                        ProgressView().controlSize(.small)
                        Text("分けています…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                switch controller.reseparation {
                case .done(let count): Label("分け直しました（話者 \(count) 人）", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
                case .failed(let reason): Label(reason, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                case .idle, .running: EmptyView()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            .confirmationDialog("分け直しますか？", isPresented: $model.confirmingReseparate) {
                Button("名前を外して、分け直す", role: .destructive) { model.reseparate() }
            } message: {
                Text("確定した名前（\(controller.namedSpeakers.count) 人）が、すべて外れ、記録が書き直されます。")
            }
        } else {
            Label("この会議の音声は、保存されていません。人数を変えて分け直したり、聞き直したりするには、設定の「相手の音声を保存する」をオンにしてください（次の会議から保存されます）。", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: 話者ごと

    private func color(_ id: Int) -> Color { Self.palette[(max(id, 1) - 1) % Self.palette.count] }

    private func card(_ speaker: SpeakerSummary) -> some View {
        let confirmed = controller.namedSpeakers[speaker.id]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(speaker.id)").font(.headline).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(Circle().fill(color(speaker.id)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("話者 \(speaker.id)").font(.headline)
                    Text("\(Self.duration(speaker.seconds))・\(speaker.utteranceCount) 発言").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusChip(speaker, confirmed: confirmed)
            }
            excerpts(speaker)
            if confirmed == nil { namingControls(speaker) }
            else if let warning = model.warnings[speaker.id] {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(confirmed == nil ? 0.08 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(confirmed == nil ? color(speaker.id).opacity(0.5) : Color.green.opacity(0.4), lineWidth: 1))
    }

    @ViewBuilder private func statusChip(_ speaker: SpeakerSummary, confirmed: String?) -> some View {
        if let name = confirmed {
            if controller.voiceMatched.contains(speaker.id) {
                Label("声紋で一致：\(name)", systemImage: "waveform.badge.checkmark").foregroundStyle(.green)
            } else {
                Label("確定：\(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            Label("未確定", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private func excerpts(_ speaker: SpeakerSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(speaker.excerpts.enumerated()), id: \.offset) { index, excerpt in
                HStack(alignment: .top, spacing: 8) {
                    if controller.namingAudioAvailable, speaker.clips.indices.contains(index) {
                        let key = "\(speaker.id)-\(index)"
                        Button { controller.toggleClip(speaker: speaker.id, index: index) } label: {
                            Image(systemName: controller.clipPlayer.playingKey == key ? "stop.circle.fill" : "play.circle.fill").font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(color(speaker.id))
                        .help(controller.clipPlayer.playingKey == key ? "止める" : "この発言を聞き直す")
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("「\(excerpt)」").font(.callout).lineLimit(3)
                        if speaker.clips.indices.contains(index) {
                            Text(Self.clock(speaker.clips[index].start)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            if let failure = controller.playbackFailure, controller.namingAudioAvailable {
                Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private func namingControls(_ speaker: SpeakerSummary) -> some View {
        let candidates = controller.namingCandidates[speaker.id] ?? []
        let hints = controller.namingHints[speaker.id] ?? []
        if !candidates.isEmpty || !hints.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if !candidates.isEmpty {
                    Text("声が似ている人（声紋）").font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(candidates, id: \.name) { candidate in
                            Button { model.drafts[speaker.id] = candidate.name } label: {
                                Label("\(candidate.name)　\(String(format: "%.2f", candidate.similarity))", systemImage: "waveform")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                if !hints.isEmpty {
                    Text("名前のヒント（内容からの推定。確定ではありません）").font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                            Button { model.drafts[speaker.id] = hint.name } label: {
                                Label(Self.hintTitle(hint), systemImage: hint.introduced ? "text.bubble" : "sparkles")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
        Divider()
        HStack {
            TextField("名前を入力（例：佐藤 花子）", text: Binding(get: { model.drafts[speaker.id] ?? "" }, set: { model.drafts[speaker.id] = $0 }))
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.confirm(speaker.id) }
            if !controller.nameCandidates.isEmpty {
                Menu {
                    ForEach(controller.nameCandidates, id: \.self) { name in
                        Button(name) { model.drafts[speaker.id] = name }
                    }
                } label: {
                    Label("出席者", systemImage: "person.crop.circle")
                }
                .fixedSize()
            }
            Button("確定") { model.confirm(speaker.id) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.working.contains(speaker.id) || (model.drafts[speaker.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if controller.voiceprintsEnabled {
            Toggle(isOn: Binding(get: { model.remember[speaker.id] ?? true }, set: { model.remember[speaker.id] = $0 })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("この声を覚える").font(.callout)
                    Text("次の会議から、同じ声の人に、この名前を付けます（声の特徴だけ保存します。音声は保存しません）").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }
        if let failure = model.failures[speaker.id] {
            Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
        }
    }

    /// 会議の表示：「題名　11/1 17:34」。
    static func meetingTitle(_ meeting: NamingMeeting) -> String {
        "\(meeting.title)　\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    /// 選びの 1 行：「題名　日時（直前）・話者 3 人（確定 1）」。
    static func choiceTitle(_ choice: MeetingController.NamingChoice) -> String {
        var text = meetingTitle(choice.meeting)
        if choice.isPrevious { text += "（直前）" }
        if let speakers = choice.speakers, let named = choice.named { text += "・話者 \(speakers) 人（確定 \(named)）" }
        return text
    }

    /// 「12 分 3 秒」（1 分未満は「45 秒」）。
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 60 ? "\(total / 60) 分 \(total % 60) 秒" : "\(total) 秒"
    }

    /// 会議の時刻「mm:ss」（1 時間以上は「h:mm:ss」）。
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

extension SpeakerNamingView {
    /// ヒントのボタンの文：「名乗りあり：佐藤 花子」・「佐藤 花子　62%」。
    static func hintTitle(_ hint: SpeakerHint) -> String {
        if hint.introduced { return "名乗りあり：\(hint.name)" }
        return "\(hint.name)　\(Int(((hint.probability ?? 0) * 100).rounded()))%"
    }
}

/// 行を折り返して並べる（候補のボタン用）。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
