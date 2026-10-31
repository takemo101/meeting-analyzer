import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("CLI：actors check と replay --actors")
struct ActorCommandTests {
    @Test("引数を一度だけ検査する")
    func parses() {
        #expect(CommandParser.parse(["actors", "check", "ACTOR.md"]) == .success(.actorsCheck(file: "ACTOR.md")))
        for bad in [["actors"], ["actors", "check"], ["actors", "list", "a"], ["actors", "check", "a", "b"]] {
            guard case .failure(.usage) = CommandParser.parse(bad) else { Issue.record("\(bad) を断らない"); return }
        }
        guard case .success(.replay(let options)) = CommandParser.parse(["replay", "a.wav", "--actors", "ACTOR.md"]) else { Issue.record("parse failed"); return }
        #expect(options.actors == "ACTOR.md")
    }

    @Test("--attendees：名前を、「,」「、」で区切って渡す。--actors と一緒でなければ断る。ACTOR.md の相手の側に無い名前は、再生の前に断る（終了コード 2）")
    func attendees() async throws {
        guard case .success(.replay(let options)) = CommandParser.parse(["replay", "a.wav", "--actors", "ACTOR.md", "--attendees", "佐藤 花子、田中 美咲, "]) else { Issue.record("parse failed"); return }
        #expect(options.attendees == ["佐藤 花子", "田中 美咲"])
        guard case .success(.replay(let plain)) = CommandParser.parse(["replay", "a.wav", "--actors", "ACTOR.md"]) else { Issue.record("parse failed"); return }
        #expect(plain.attendees == nil)
        guard case .failure(.usage) = CommandParser.parse(["replay", "a.wav", "--attendees", "佐藤 花子"]) else { Issue.record("--actors なしを断らない"); return }

        let actors = tempURL("attendees-actors", ext: "md")
        try Data(actorSample.utf8).write(to: actors)
        let err = Collected<String>()
        let run = ReplayOptions(file: actors.path, speaker: .others, title: "m", locale: "ja_JP", hold: 0, wait: 0, actors: actors.path, attendees: ["高橋 健", "山田 太郎"])
        let code = await CLIRunner(environment: ["MEETING_ANALYZER_DATA_DIR": tempURL("attendees-data").path], out: { _ in }, err: { err.add($0) }).run(.replay(run))
        #expect(code == 2 && (err.values.first ?? "").contains("高橋 健") && (err.values.first ?? "").contains("山田 太郎"), "\(err.values)")
    }
}

@Suite("アクターを作る skill: 例が、実際に読めること")
struct ActorAuthoringSkillTests {
    private func skillText() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("skills/meeting-analyzer-actors/SKILL.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("skill の見出しがあり、完成例が、アプリと同じ規則で読める")
    func exampleParses() throws {
        let text = try skillText()
        #expect(text.hasPrefix("---\nname: meeting-analyzer-actors\ndescription: "))
        let start = try #require(text.range(of: "```markdown\n"))
        let end = try #require(text.range(of: "\n```", range: start.upperBound..<text.endIndex))
        let list = try ActorList.parse(String(text[start.upperBound..<end.lowerBound])).get()
        #expect(list.actors.count == 4 && list.selfActor?.name == "山田 太郎" && list.warnings.isEmpty)
    }
}
