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

/// 分割した 1 区間（本文と、付けた名前。付けられなければ `nil`）。
public struct LabeledSegment: Sendable, Equatable {
    public let text: String
    public let actor: ActorLabel?

    public init(text: String, actor: ActorLabel?) {
        self.text = text
        self.actor = actor
    }
}

/// 確定した発話を、**話者ごとの区間に分け**、それぞれにアクターを付ける部品（`LiveSession`・再生が使う。SPEC §3.13）。
/// 「本人」（マイク）は、分けず、`ACTOR.md` の本人へ対応づける（推定ではない）。「相手」は、`guesser` があるときだけ、内容から分けて推定する。
/// 付けられないときは `nil`（「本人」「相手」のまま）。推定が失敗したら投げる（呼び出し側が、知らせて、以後は付けずに続ける）。
public struct SpeakerLabeler: Sendable {
    public let segments: @Sendable (Speaker, String) async throws -> [LabeledSegment]

    public init(segments: @escaping @Sendable (Speaker, String) async throws -> [LabeledSegment]) {
        self.segments = segments
    }

    public init(list: ActorList, guesser: SpeakerGuesser?) {
        let myself = list.selfActor.map { ActorLabel(name: $0.name, guessed: false) }
        self.init { speaker, text in
            switch speaker {
            case .you: return [LabeledSegment(text: text, actor: myself)]
            case .others:
                guard let guesser else { return [LabeledSegment(text: text, actor: nil)] }
                return try await guesser.segments(text).map { LabeledSegment(text: $0.text, actor: $0.actor.map { ActorLabel(name: $0.name, guessed: true) }) }
            }
        }
    }

    /// 認識の更新 1 つを、区間ごとの更新に分ける。**「相手」は、確定した更新だけ**（暫定の文は、分けず、名前も付けない）。
    /// 区間が 1 つなら、元の更新（本文・時刻そのまま）に、名前だけを付ける。複数なら、元の時刻（開始〜終了）を、区間の文字数で按分する。
    public func split(_ update: TranscriptionUpdate, speaker: Speaker) async throws -> [(update: TranscriptionUpdate, actor: ActorLabel?)] {
        if speaker == .others, !update.isFinal { return [(update, nil)] }
        let parts = try await segments(speaker, update.text)
        guard parts.count > 1 else { return [(update, parts.first?.actor)] }
        let total = max(1, parts.reduce(0) { $0 + $1.text.count })
        var done = 0
        return parts.map { part in
            let from = update.start + (update.end - update.start) * Double(done) / Double(total)
            done += part.text.count
            let to = update.start + (update.end - update.start) * Double(done) / Double(total)
            return (TranscriptionUpdate(text: part.text, isFinal: update.isFinal, start: from, end: to), part.actor)
        }
    }
}

extension SpeakerLabeler {
    /// `ACTOR.md` の一覧から、labeler を作る（会議・再生が、同じ手順を使う）。
    /// 判断モデルがあり、相手の側の候補がいるときだけ、モデルを読み込んで、推定できる labeler にする。**無いときは、推定しない**（「本人」の対応づけだけ。相手は「相手」のまま。SPEC §3.13）。
    /// **重い**（初回は、GPU のグラフのコンパイルで数秒）ので、呼び出し側は、画面を止めない場所（別のスレッド）で呼ぶ。読み込めなければ、`DecisionModelError` を投げる（見せ方は、呼び出し側の境界が決める）。
    public static func make(list: ActorList, model: DecisionModel?, store: ModelStore, attendance: Attendance, unit: JudgmentUnit = .default) throws -> SpeakerLabeler {
        guard let model, !list.others.isEmpty else { return SpeakerLabeler(list: list, guesser: nil) }
        let judge = try SystemOneJudge(model: model, store: store, candidates: list.others)
        try judge.prepare()
        return SpeakerLabeler(list: list, guesser: SpeakerGuesser(list: list, judge: judge, attendance: attendance, unit: unit))
    }
}
