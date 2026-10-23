/// システム音声（Mac から出ている音）の取り込み先。
public enum SystemSource: Sendable, Hashable {
    /// 取り込まない。
    case off
    /// Mac から出ている音すべて（このアプリ自身の音は除く）。動画や通知音も混ざる。
    case all
    /// 選んだアプリの音だけ。
    case app(bundleID: String, name: String)
}

/// 取り込む音声の選択（SPEC §3.3）。マイク（本人）とシステム音声（相手）を、それぞれ選ぶ。
public struct AudioSelection: Sendable, Equatable {
    public var microphone: Bool
    public var system: SystemSource

    public init(microphone: Bool = true, system: SystemSource = .off) {
        self.microphone = microphone
        self.system = system
    }

    /// 取り込む流れ。本人（マイク）、相手（システム音声）の順。
    public var speakers: [Speaker] {
        var result: [Speaker] = []
        if microphone { result.append(.you) }
        if system != .off { result.append(.others) }
        return result
    }

    /// 何も選ばれていない（開始できない）。
    public var isEmpty: Bool { speakers.isEmpty }

    /// 選択の短い説明。メニューと、セッションの名前に使う。
    public var summary: String {
        var parts: [String] = []
        if microphone { parts.append("マイク") }
        switch system {
        case .off: break
        case .all: parts.append("システム全体")
        case .app(_, let name): parts.append(name)
        }
        return parts.isEmpty ? "未選択" : parts.joined(separator: "＋")
    }
}
