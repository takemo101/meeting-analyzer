import Foundation

/// 会議の操作（一時停止・再開・終了）を、**同時に 1 つだけ**進める。進行中の操作は 1 つの `Task` で、あとから来た操作は、`idle()` でその完了を待つ（時間を置いて状態を見直す待ちはしない）。
/// 終了が、一時停止・再開の最中に来ても、取り込みの停止が重ならない。
@MainActor
final class OperationGate {
    private var current: Task<Void, Never>?
    /// 操作の通し番号（終わった操作が、あとから始まった操作の「進行中」を消さないため）。
    private var generation = 0

    /// 操作を始める（呼ぶ側が、`idle()` で、前の操作の完了を待ってから）。終わると、進行中ではなくなる。
    @discardableResult
    func run(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        generation += 1
        let mine = generation
        let task = Task {
            await operation()
            if generation == mine { current = nil }
        }
        current = task
        return task
    }

    /// 進行中の操作が無くなるまで待つ（待っている間に、別の操作が始まったら、それも待つ）。
    func idle() async {
        while let current { await current.value }
    }
}
