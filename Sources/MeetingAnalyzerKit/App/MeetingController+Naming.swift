import Foundation

/// 話者の名付け（SPEC §3.15）：直前の会議の、声で分けた話者（話者 N）に、人間が名前を付ける。
extension MeetingController {
    /// 名前を付けていない話者が、1 人以上いるか（メニューの「話者の名付け…」を出す条件）。
    var canNameSpeakers: Bool {
        namingSession != nil && namingSpeakers.contains { namedSpeakers[$0.id] == nil }
    }

    /// 名前の選択肢（出席者。ACTOR.md を選んでいなければ、空。自分で入力することもできる）。
    var nameCandidates: [String] {
        actorChoices.filter(\.present).map(\.name)
    }

    /// 話者 N に、名前を確定する。記録を書き直し、`speakers` の出来事を出す。失敗の理由（画面に見せる文）を返す。成功なら `nil`。
    func confirmSpeakerName(_ id: Int, name: String) async -> String? {
        guard let session = namingSession else { return "名付けできる会議がありません（次の会議を始めたあとは、名付けられません）" }
        switch await session.nameSpeakers([id: name]) {
        case .success(let named):
            for item in named.speakers { namedSpeakers[item.speaker] = item.name }
            changed()
            return nil
        case .failure(let error):
            return error.message
        }
    }

    /// 次の会議の開始のとき、名付けの対象を手放す（話者 N のままの人は、そのまま）。
    func clearNaming() {
        guard namingSession != nil || !namingSpeakers.isEmpty else { return }
        namingSession = nil
        namingSpeakers = []
        namedSpeakers = [:]
        changed()
    }
}
