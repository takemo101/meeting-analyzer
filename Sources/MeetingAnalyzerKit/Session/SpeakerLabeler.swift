import Foundation

/// 会議で使う `ACTOR.md`：読み込んだ一覧と、元のファイルの絶対パス（開始の出来事で、エージェントへ渡す。SPEC §3.13）。
public struct ActorSource: Sendable, Equatable {
    public let list: ActorList
    public let file: String

    public init(list: ActorList, file: String) {
        self.list = list
        self.file = file
    }
}

/// 確定した発話に、アクターを付ける部品（`LiveSession`・再生が使う）。
/// 「本人」（マイク）は、`ACTOR.md` の本人へ対応づける（推定ではない）。「相手」は、内容から推定する（`guesser` があるときだけ）。
/// 付けられないときは `nil`（「本人」「相手」のまま）。推定が失敗したら投げる（呼び出し側が、知らせて、以後は付けずに続ける）。
public struct SpeakerLabeler: Sendable {
    public let label: @Sendable (Speaker, String) async throws -> ActorLabel?

    public init(label: @escaping @Sendable (Speaker, String) async throws -> ActorLabel?) {
        self.label = label
    }

    public init(list: ActorList, guesser: SpeakerGuesser?) {
        let myself = list.selfActor.map { ActorLabel(name: $0.name, guessed: false) }
        self.init { speaker, text in
            switch speaker {
            case .you: return myself
            case .others:
                guard let guesser, let actor = try await guesser.guess(text) else { return nil }
                return ActorLabel(name: actor.name, guessed: true)
            }
        }
    }
}
