/// 発言者の区別。マイクが「本人」、システム音声（会議アプリ）が「相手」。相手が複数人でも区別しない（SPEC §3.3）。
public enum Speaker: String, Sendable, Equatable, CaseIterable {
    case you
    case others

    /// エージェントへ送る表示名。skill はこの値で「本人の発言」を判断する。
    public var displayName: String {
        switch self {
        case .you: return "本人"
        case .others: return "相手"
        }
    }
}
