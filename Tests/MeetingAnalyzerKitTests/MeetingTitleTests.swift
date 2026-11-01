import Testing
@testable import MeetingAnalyzerKit

@Suite("会議の題名の規則")
struct MeetingTitleTests {
    @Test("前後と連続する空白を整える")
    func trims() {
        #expect(MeetingTitleRule.normalize("  週次の定例   第 3 回  ") == "週次の定例 第 3 回")
    }

    @Test("空・空白だけは、自動の題名を使う（nil）")
    func emptyIsNil() {
        #expect(MeetingTitleRule.normalize("") == nil)
        #expect(MeetingTitleRule.normalize(" \t　\n ") == nil)
    }

    @Test("改行・制御文字は、記録の見出しの行を壊さないよう、空白にする")
    func newlinesBecomeSpaces() {
        #expect(MeetingTitleRule.normalize("定例\n- 名前: 偽\r\n終わり") == "定例 - 名前: 偽 終わり")
    }

    @Test("80 文字までにする")
    func limit() {
        let title = MeetingTitleRule.normalize(String(repeating: "あ", count: 200))
        #expect(title?.count == MeetingTitleRule.maxLength)
    }
}
