import Foundation

/// 会議で使う `ACTOR.md`：読み込んだ一覧と、元のファイルの絶対パス（開始の出来事で、エージェントへ渡す。SPEC §3.13）。
/// 「本人」（マイク）の発話には、一覧の本人の名前を付ける（決まった対応で、推定ではない）。「相手」の名前は、会議のあとに、人間が確定する（SPEC §3.15）。
public struct ActorSource: Sendable, Equatable {
    public let list: ActorList
    public let file: String

    public init(list: ActorList, file: String) {
        self.list = list
        self.file = file
    }

    /// 「本人」の発話に付ける名前（`本人: はい` の人。無ければ `nil`）。
    public var selfName: String? { list.selfActor?.name }
}
