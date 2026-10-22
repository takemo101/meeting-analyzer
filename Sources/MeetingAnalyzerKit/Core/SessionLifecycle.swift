/// 会議（セッション）が終わった理由。
public enum EndReason: String, Sendable, Equatable {
    /// 利用者が終了を指示した。
    case user
    /// 音声が一定時間なかったので、自動で終了した（SPEC §3.8。既定は無効）。
    case silence
    /// アプリが終了された。
    case appQuit
}

/// セッションの状態遷移。終わったセッションは、開始し直せない（新しいセッションを作る）。
public struct SessionLifecycle: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case running
        case paused
        case ended(EndReason)
    }

    public enum TransitionError: Error, Sendable, Equatable {
        case invalid(from: Phase, action: String)
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    public mutating func start() throws {
        guard phase == .idle else { throw TransitionError.invalid(from: phase, action: "start") }
        phase = .running
    }

    public mutating func pause() throws {
        guard phase == .running else { throw TransitionError.invalid(from: phase, action: "pause") }
        phase = .paused
    }

    public mutating func resume() throws {
        guard phase == .paused else { throw TransitionError.invalid(from: phase, action: "resume") }
        phase = .running
    }

    /// 実行中・一時停止中のどちらからでも終了できる。
    public mutating func end(_ reason: EndReason) throws {
        guard phase == .running || phase == .paused else { throw TransitionError.invalid(from: phase, action: "end") }
        phase = .ended(reason)
    }

    /// 字幕を処理してよいか。一時停止中と、始まる前・終わった後は処理しない。
    public var isProcessing: Bool { phase == .running }
}
