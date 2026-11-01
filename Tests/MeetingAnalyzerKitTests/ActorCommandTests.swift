import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("CLI：actors check・actors try と replay --actors")
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

    @Test("actors try --attendees：ACTOR.md の相手の側に無い名前は、モデルを読む前に断る（終了コード 2。有る名前の一覧を示す）")
    func attendeesMustBeKnown() async throws {
        let actors = tempURL("attendees-actors", ext: "md")
        try Data(actorSample.utf8).write(to: actors)
        defer { try? FileManager.default.removeItem(at: actors) }
        let err = Collected<String>()
        let options = ActorsTryOptions(file: actors.path, judge: "tiny-jev-0.6b", attendees: ["高橋 健", "山田 太郎"], input: .text("来週の予定を確認します"))
        let code = await CLIRunner(environment: ["MEETING_ANALYZER_DATA_DIR": tempURL("attendees-data").path], out: { _ in }, err: { err.add($0) }).run(.actorsTry(options))
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
