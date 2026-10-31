import Foundation
import Testing
@testable import MeetingAnalyzerKit

@Suite("SpeakerLabeler.make: 判断モデルの読み込みと、labeler の組み立てを、1 か所で")
struct SpeakerLabelerMakeTests {
    private func list(_ text: String = "## 山田 太郎\n- 本人: はい\n\n## 佐藤 花子\n") throws -> ActorList { try ActorList.parse(text).get() }
    private func emptyStore() -> ModelStore { ModelStore(root: tempURL("labeler-make")) }

    @Test("判断モデルが無ければ、推定しない：「本人」は一覧の本人へ対応づけ（推定ではない）、「相手」は付けない")
    func withoutModel() async throws {
        let labeler = try SpeakerLabeler.make(list: try list(), model: nil, store: emptyStore(), attendance: Attendance())
        #expect(try await labeler.segments(.you, "確認します") == [LabeledSegment(text: "確認します", actor: ActorLabel(name: "山田 太郎", guessed: false))])
        #expect(try await labeler.segments(.others, "月末の締め処理に間に合うかが関心事です") == [LabeledSegment(text: "月末の締め処理に間に合うかが関心事です", actor: nil)])
    }

    @Test("相手の側の候補がいなければ（本人だけの一覧）、モデルを選んでいても、読み込まない（取得されていなくても、失敗しない）")
    func withoutCandidates() throws {
        let onlyMe = try list("## 山田 太郎\n- 本人: はい\n")
        _ = try SpeakerLabeler.make(list: onlyMe, model: try #require(DecisionModelCatalog.all.first), store: emptyStore(), attendance: Attendance())
    }

    @Test("モデルが取得されていなければ、DecisionModelError で投げる（会議は、呼び出し側が、推定なしで始める）")
    func missingModelThrows() throws {
        #expect(throws: DecisionModelError.self) {
            try SpeakerLabeler.make(list: try list(), model: try #require(DecisionModelCatalog.all.first), store: emptyStore(), attendance: Attendance())
        }
    }
}
