import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("ACTOR.md：読み取り")
struct ActorListTests {
    @Test("「## 名前」の節ごとに、役割・呼ばれ方・話題・本人を読む。区切りは、「、」「,」。説明の文章は、読まない")
    func parsesSections() throws {
        let actors = try actorList().actors
        #expect(actors.map(\.name) == ["山田 太郎", "佐藤 花子", "田中 美咲"])
        #expect(actors[0].role == "プロダクトマネージャー" && actors[0].aliases == ["山田さん", "PM"] && actors[0].topics == ["優先順位", "スケジュール"] && actors[0].isSelf)
        #expect(actors[1].topics == ["API・データベース"] && !actors[1].isSelf)
        #expect(try actorList().selfActor?.name == "山田 太郎")
        #expect(try actorList().others.map(\.name) == ["佐藤 花子", "田中 美咲"])
        #expect(try actorList().summary == "山田 太郎（本人）、佐藤 花子、田中 美咲")
    }

    @Test("使えない項目は、止めずに、警告にする（知らない項目名・「本人」の値の誤り）。使える部分は、読む")
    func warnsAndContinues() throws {
        let parsed = try actorList("## 山田 太郎\n- 役職: 部長\n- 本人: たぶん\n- 役割: PM\n")
        #expect(parsed.actors == [Actor(name: "山田 太郎", role: "PM")])
        #expect(parsed.warnings.count == 2)
    }

    @Test("読めない一覧は、理由つきで断る：アクターが無い・同じ名前・本人が 2 人・多すぎる")
    func rejects() {
        #expect(ActorList.parse("# だけ\n説明") == .failure(.empty))
        #expect(ActorList.parse("## 山田\n## 山田\n") == .failure(.duplicate("山田")))
        #expect(ActorList.parse("## 山田\n- 本人: はい\n## 佐藤\n- 本人: yes\n") == .failure(.multipleSelf(["山田", "佐藤"])))
        let many = (1...13).map { "## 人\($0)\n" }.joined()
        #expect(ActorList.parse(many) == .failure(.tooMany(max: ActorList.maxActors)))
    }
}

@Suite("ACTOR.md のファイル：大きさ・文字コード・書式を、読むときに一度だけ検査する")
struct ActorFileTests {
    private func write(_ data: Data) throws -> String {
        let url = tempURL("actor-file", ext: "md")
        try data.write(to: url)
        return url.path
    }

    @Test("読める・読めない（無い・大きすぎる・UTF-8 でない・書式の誤り）")
    func loads() throws {
        #expect(try ActorFile.load(path: write(Data(actorSample.utf8))).get().actors.count == 3)
        #expect(ActorFile.load(path: "/no/such/ACTOR.md") == .failure(.notReadable("/no/such/ACTOR.md")))
        guard case .failure(.tooLarge) = ActorFile.load(path: try write(Data(repeating: 0x61, count: ActorFile.maxBytes + 1))) else { Issue.record("大きすぎるファイルを断らない"); return }
        #expect(ActorFile.load(path: try write(Data([0xFF, 0xFE, 0x00]))) == .failure(.notUTF8))
        #expect(ActorFile.load(path: try write(Data("説明だけ".utf8))) == .failure(.invalid(.empty)))
    }

    @Test("設定の保存：ACTOR.md のパスと、判断モデルの ID を覚える。絶対パスでない値・知らないモデルは、無しに戻す")
    func preferences() throws {
        let defaults = try #require(UserDefaults(suiteName: "ma-actors-" + UUID().uuidString))
        var saved = CapturePreferences()
        saved.actorFile = "/work/ACTOR.md"
        saved.decisionModel = "tiny-jev-0.6b"
        saved.save(defaults)
        let loaded = CapturePreferences.load(defaults)
        #expect(loaded.actorFile == "/work/ACTOR.md" && loaded.decisionModel == "tiny-jev-0.6b")
        defaults.set("relative/ACTOR.md", forKey: CapturePreferences.keys.actorFile)
        #expect(CapturePreferences.load(defaults).actorFile == nil)
        defaults.set("no-such-model", forKey: CapturePreferences.keys.decisionModel)
        #expect(CapturePreferences.load(defaults).decisionModel == nil, "知らないモデルの ID は、推定しない")
        #expect(CapturePreferences.load(try #require(UserDefaults(suiteName: "ma-actors-" + UUID().uuidString))).decisionModel == nil, "既定は、推定しない")
    }

    @Test("最近の ACTOR.md：選んだものが先頭に来る（重複しない）。上限を超えた古いものは捨てる。外した人は、ファイルごとに覚える。壊れた値は、その項目だけ捨てる")
    func recentFilesAndAbsentActors() throws {
        var saved = CapturePreferences()
        for index in 0..<(CapturePreferences.maxActorFiles + 2) { saved.remember(actorFile: "/p\(index)/ACTOR.md") }
        saved.remember(actorFile: "/p5/ACTOR.md")
        #expect(saved.actorFiles.count == CapturePreferences.maxActorFiles)
        #expect(saved.actorFiles.first == "/p5/ACTOR.md" && saved.actorFiles.filter { $0 == "/p5/ACTOR.md" }.count == 1)
        #expect(!saved.actorFiles.contains("/p0/ACTOR.md"), "古いものから捨てる")

        saved.actorFile = "/p5/ACTOR.md"
        saved.setAbsent(["田中 美咲", "高橋 健"], for: "/p5/ACTOR.md")
        saved.setAbsent(["鈴木 一郎"], for: "/p1/ACTOR.md")
        let defaults = try #require(UserDefaults(suiteName: "ma-actors-" + UUID().uuidString))
        saved.save(defaults)
        #expect(CapturePreferences.load(defaults) == saved)
        saved.setAbsent([], for: "/p1/ACTOR.md")
        #expect(saved.absentActors["/p1/ACTOR.md"] == nil, "全員出席に戻したら、項目ごと消す")

        // 一覧の項目が無かった版の設定（選んでいる ACTOR.md だけ）を引き継ぐ。壊れた値は、その項目だけ捨てる。
        let old = try #require(UserDefaults(suiteName: "ma-actors-" + UUID().uuidString))
        old.set("/old/ACTOR.md", forKey: CapturePreferences.keys.actorFile)
        #expect(CapturePreferences.load(old).actorFiles == ["/old/ACTOR.md"])
        old.set(["/a/ACTOR.md", "relative/ACTOR.md", "/a/ACTOR.md"], forKey: CapturePreferences.keys.actorFiles)
        old.set(["/a/ACTOR.md": ["田中 美咲"], "relative": ["x"], "/b/ACTOR.md": []], forKey: CapturePreferences.keys.absentActors)
        let loaded = CapturePreferences.load(old)
        #expect(loaded.actorFiles == ["/old/ACTOR.md", "/a/ACTOR.md"], "選んでいるものが、先頭")
        #expect(loaded.absentActors == ["/a/ACTOR.md": ["田中 美咲"]])
    }
}
