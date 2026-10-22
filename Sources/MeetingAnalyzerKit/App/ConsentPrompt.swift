import AppKit

/// 開始の前の、同意の確認（SPEC §3.10）。3 つすべてにチェックしないと、開始できない。確認なしには、取り込み（と、権限の要求）を始めない。
@MainActor
enum ConsentPrompt {
    static let statements = [
        "参加者に、会議の音声を文字にして、エージェントへ送ることを伝え、同意を得ている",
        "所属する組織の規程で、会議の文字起こしと、外部サービスへの送信が許されている",
        "送信先のエージェント（例：Claude Code）の、データの取り扱いを確認した",
    ]

    /// 「開始」が選ばれたら true。取り込む音声（選択）を、ダイアログに示す。
    static func confirm(selection: AudioSelection) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "音声を文字にして始めます（\(selection.summary)）"
        alert.informativeText = "\(sourceText(selection))を、この Mac の中で文字にして、ローカルのエージェントへ送ります。音声は保存も送信もしません。終了で、記録を保存し、エージェントへ終了を知らせます。次を確認してください。"
        let start = alert.addButton(withTitle: "開始")
        alert.addButton(withTitle: "キャンセル")
        start.isEnabled = false

        let gate = Gate(button: start)
        let boxes = statements.map { NSButton(checkboxWithTitle: $0, target: gate, action: #selector(Gate.changed)) }
        gate.boxes = boxes
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack

        return withExtendedLifetime(gate) { alert.runModal() == .alertFirstButtonReturn }
    }

    private static func sourceText(_ selection: AudioSelection) -> String {
        var parts: [String] = []
        if selection.microphone { parts.append("マイク（あなた）") }
        switch selection.system {
        case .off: break
        case .all: parts.append("Mac から出ている音すべて（相手。動画や通知音も含む）")
        case .app(_, let name): parts.append("「\(name)」の音声（相手）")
        }
        return parts.joined(separator: "と")
    }

    @MainActor
    private final class Gate: NSObject {
        let button: NSButton
        var boxes: [NSButton] = []

        init(button: NSButton) { self.button = button }

        @objc func changed() {
            button.isEnabled = boxes.allSatisfy { $0.state == .on }
        }
    }
}
