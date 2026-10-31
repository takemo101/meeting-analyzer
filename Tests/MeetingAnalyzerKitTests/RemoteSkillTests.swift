import Foundation
import AppKit
import Testing
@testable import MeetingAnalyzerKit

@Suite("リモートの skill を使う指示：URL は、リポジトリの実在する SKILL.md を指す")
struct RemoteSkillTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("どの指示も、リポジトリに実在する skills/<名前>/SKILL.md の URL を指す（フォルダの改名で、指示が切れない）。名前は、それぞれ違う")
    func urlsPointAtExistingSkills() {
        for skill in RemoteSkill.allCases {
            let path = "skills/\(skill.directory)/SKILL.md"
            #expect(FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent(path).path), "\(path)")
            #expect(skill.url(ref: "main") == "https://raw.githubusercontent.com/takemo101/meeting-analyzer/main/\(path)")
        }
        #expect(Set(RemoteSkill.allCases.map(\.directory)).count == RemoteSkill.allCases.count)
    }

    @Test("指示は「Read <URL>, then …」の形。既定は、このアプリの版のタグ（手順を、アプリと合わせる）。ブランチ・タグを選べる")
    func promptShape() {
        for skill in RemoteSkill.allCases {
            #expect(skill.prompt().hasPrefix("Read \(skill.url(ref: "v" + AppInfo.version)), then "))
            #expect(skill.prompt(ref: "main").hasPrefix("Read \(skill.url(ref: "main")), then "))
            #expect(!skill.prompt().contains("\n"), "1 行（貼りやすい）")
        }
        #expect(Set(RemoteSkill.allCases.map { $0.prompt() }).count == RemoteSkill.allCases.count, "頼みごとが、それぞれ違う")
    }
}

@Suite("設定ウィンドウ：skill の指示をコピーする")
@MainActor
struct SettingsCopyTests {
    @Test("コピーすると、その skill の指示が、クリップボードへ入る（置き換わる）。ボタンは、少しの間、「コピーした」状態になる")
    func copiesThePrompt() {
        let root = tempURL("settings-copy")
        let controller = MeetingController(environment: ["MEETING_ANALYZER_DATA_DIR": root.path, "MEETING_ANALYZER_SOCKET": "/tmp/ma-\(UUID().uuidString.prefix(8)).sock"], defaults: UserDefaults(suiteName: "ma-test-\(UUID().uuidString)")!)
        let model = SettingsModel(controller: controller)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ma-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.setString("前の内容", forType: .string)
        model.copy(.presets, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == RemoteSkill.presets.prompt())
        #expect(model.copiedSkill == .presets)
        model.copy(.actors, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == RemoteSkill.actors.prompt(), "次のコピーで置き換わる")
        #expect(model.copiedSkill == .actors)
    }
}
