import Foundation
/// 送信のまとめ方（SPEC §3.6）。値は live-support の「発話の区切りごと」と同じ。
public struct BatchingPolicy: Sendable, Equatable {
    /// 変化がこの秒数止まったら、発話が区切れたとみなして送る。
    public var quiet: TimeInterval
    /// 最も古い未送信の変化がこの秒数たったら、途切れなくても送る。
    public var maxHold: TimeInterval
    /// 新しい発話が始まったとき、前の発話を送るが、直前の送信からこの秒数は空ける。
    public var boundaryGap: TimeInterval
    /// 1 回に送る発話の最大数（ブリッジの上限）。
    public var maxUpdates: Int

    public init(quiet: TimeInterval = 1.2, maxHold: TimeInterval = 10, boundaryGap: TimeInterval = 3, maxUpdates: Int = 64) {
        self.quiet = quiet
        self.maxHold = maxHold
        self.boundaryGap = boundaryGap
        self.maxUpdates = maxUpdates
    }

    public static let standard = BatchingPolicy()
}

/// 発話の更新を溜めて、送るべき時にバッチにして返す。時計を持たず、`now`（秒）を引数で受ける純粋な規則。
public struct Batcher: Sendable {
    public let policy: BatchingPolicy
    private var latest: [String: Utterance] = [:]
    private var pendingKeys: [String] = []
    private var lastChange: TimeInterval
    private var pendingSince: TimeInterval?
    private var boundary = false
    private var lastSent: TimeInterval

    public init(policy: BatchingPolicy = .standard, startedAt: TimeInterval = 0) {
        self.policy = policy
        self.lastChange = startedAt
        self.lastSent = startedAt
    }

    /// 未送信の発話があるか。
    public var hasPending: Bool { !pendingKeys.isEmpty }

    /// 発話の更新を受ける。本文も確定状態も同じ更新は、変化として数えない。
    public mutating func observe(_ utterance: Utterance, at now: TimeInterval) {
        let known = latest[utterance.key]
        if let known, known.text == utterance.text, known.isFinal == utterance.isFinal { return }
        // 未送信の変化があるところへ新しい発話が始まったら、前の発話は終わったとみなす（境界）。
        if known == nil, pendingSince != nil { boundary = true }
        latest[utterance.key] = utterance
        if !pendingKeys.contains(utterance.key) { pendingKeys.append(utterance.key) }
        lastChange = now
        pendingSince = pendingSince ?? now
    }

    /// 今、送るべきか。
    public func isDue(at now: TimeInterval) -> Bool {
        guard let since = pendingSince else { return false }
        return now - lastChange >= policy.quiet
            || now - since >= policy.maxHold
            || (boundary && now - lastSent >= policy.boundaryGap)
    }

    /// 送るべきときだけ、未送信の発話（最大 `maxUpdates`）を返して、送信済みにする。
    public mutating func takeBatch(at now: TimeInterval) -> [Utterance]? {
        isDue(at: now) ? flush(at: now) : nil
    }

    /// 送るべきかに関わらず、未送信の発話（最大 `maxUpdates`）を返す。会議の終了時に、残りを出し切るのに使う。残りがあれば、また呼べる。
    public mutating func flush(at now: TimeInterval) -> [Utterance] {
        let taken = Array(pendingKeys.prefix(policy.maxUpdates))
        pendingKeys.removeFirst(taken.count)
        let batch = taken.compactMap { latest[$0] }
        lastSent = now
        boundary = false
        // 上限を超えた残りは、すぐ次に送れるよう、保持の起点をいまにする。
        pendingSince = pendingKeys.isEmpty ? nil : now
        return batch
    }
}
