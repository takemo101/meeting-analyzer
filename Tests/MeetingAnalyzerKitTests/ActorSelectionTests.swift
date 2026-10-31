import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("ACTOR.md の選択：出席者はファイルごとに覚える。会議の実行中は、開始のときの一覧を見せる")
@MainActor
struct ActorSelectionTests {
    private func write(_ names: [String], to root: URL, file: String) throws -> String {
        let text = (["## 山田 太郎\n- 本人: はい"] + names.map { "## \($0)\n- 役割: 営業" }).joined(separator: "\n\n")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(file).path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("外した人は、選んだファイルごとに覚え、別のファイルへ切り替えると、そのファイルで外した人に変わる。全員戻すと、項目が消える")
    func absenceIsPerFile() throws {
        let root = tempURL("actor-selection")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write(["佐藤 花子", "田中 美咲"], to: root, file: "a.md"), b = try write(["佐藤 花子"], to: root, file: "b.md")
        let selection = ActorSelection()
        var preferences = CapturePreferences()

        #expect(selection.setPresent("佐藤 花子", false, in: &preferences) == false, "ファイルを選んでいなければ、何もしない")

        selection.select(a, in: &preferences)
        #expect(selection.setPresent("佐藤 花子", false, in: &preferences))
        #expect(preferences.absentActors[a] == ["佐藤 花子"] && preferences.actorFiles == [a])
        #expect(selection.choices(file: a, meetingRunning: false).map(\.present) == [false, true])

        selection.select(b, in: &preferences)
        #expect(selection.choices(file: b, meetingRunning: false).map(\.present) == [true], "b.md では、まだ誰も外していない")
        #expect(preferences.actorFiles == [b, a], "最近使った順")

        selection.select(a, in: &preferences)
        #expect(selection.choices(file: a, meetingRunning: false).map(\.present) == [false, true], "a.md へ戻すと、外した人が戻る")
        _ = selection.setPresent("佐藤 花子", true, in: &preferences)
        #expect(preferences.absentActors[a] == nil)

        selection.select(nil, in: &preferences)
        #expect(preferences.actorFile == nil && selection.choices(file: nil, meetingRunning: false).isEmpty)
    }

    @Test("会議の実行中は、開始のときに読んだ一覧を見せる：その後ファイルが書き換わっても、変わらない。待機中は、いま読む")
    func runningShowsTheStartingList() async throws {
        let root = tempURL("actor-running")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try write(["佐藤 花子"], to: root, file: "a.md")
        let selection = ActorSelection()
        let setup = await selection.prepare(file: path, usesSystemAudio: false, model: nil, store: ModelStore(root: root))
        #expect(setup.actors != nil && setup.labeler != nil && setup.notice == nil)

        _ = try write(["佐藤 花子", "田中 美咲"], to: root, file: "a.md")
        #expect(selection.choices(file: path, meetingRunning: true).map(\.name) == ["佐藤 花子"])
        #expect(selection.choices(file: path, meetingRunning: false).map(\.name) == ["佐藤 花子", "田中 美咲"])
    }

    @Test("読めないファイルでは、付けずに始め、理由を知らせる。選んでいなければ、何もしない")
    func unreadableOrNone() async {
        let root = tempURL("actor-missing")
        let selection = ActorSelection()
        let none = await selection.prepare(file: nil, usesSystemAudio: true, model: nil, store: ModelStore(root: root))
        #expect(none.actors == nil && none.labeler == nil && none.notice == nil)
        let missing = await selection.prepare(file: root.appendingPathComponent("無い.md").path, usesSystemAudio: true, model: nil, store: ModelStore(root: root))
        #expect(missing.actors == nil && missing.labeler == nil && missing.notice?.hasPrefix("ACTOR.md を使えません") == true)
        #expect(selection.status(file: nil) == .none)
    }
}

@Suite("会議の操作は、同時に 1 つだけ進む：あとから来た操作は、進行中の操作の完了を待つ")
@MainActor
struct OperationGateTests {
    private final class Log {
        var items: [String] = []
    }

    @Test("待つ側は、進行中の操作が終わってから進む。進行中が無ければ、すぐ返る")
    func waitersFollowTheOperation() async {
        let gate = OperationGate()
        let log = Log()
        gate.run {
            try? await Task.sleep(for: .milliseconds(50))
            log.items.append("pause")
        }
        await gate.idle()
        log.items.append("end-starts")
        #expect(log.items == ["pause", "end-starts"])
        await gate.idle()
    }

    @Test("待っている間に次の操作が始まっても、それが終わるまで待つ")
    func waitsForTheChain() async {
        let gate = OperationGate()
        let log = Log()
        gate.run {
            try? await Task.sleep(for: .milliseconds(30))
            log.items.append("first")
            gate.run {
                try? await Task.sleep(for: .milliseconds(30))
                log.items.append("second")
            }
        }
        await gate.idle()
        #expect(log.items == ["first", "second"])
    }
}
