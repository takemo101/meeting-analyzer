import Foundation

/// 今日の会議の出席者（SPEC §3.13）。`ACTOR.md` の人のうち、**外した人の名前だけ**を持つ（既定は全員出席。あとから ACTOR.md に足された人は、出席）。
/// 会議の途中でも変えられ、変えたあとの判断から効く（判断のたびに、`present` で候補を絞る）。メニュー（メインスレッド）と、判断（別のスレッド）が、同時に触るので、ロックで守る。
public final class Attendance: @unchecked Sendable {
    private let lock = NSLock()
    private var excluded: Set<String>

    public init(excluded: Set<String> = []) {
        self.excluded = excluded
    }

    public func isPresent(_ name: String) -> Bool {
        lock.withLock { !excluded.contains(name) }
    }

    public func setPresent(_ name: String, _ present: Bool) {
        lock.withLock {
            if present { excluded.remove(name) } else { excluded.insert(name) }
        }
    }

    /// 外した人の名前を、まとめて置き換える（ACTOR.md を選び直したとき）。
    public func replace(excluded names: Set<String>) {
        lock.withLock { excluded = names }
    }

    public var excludedNames: Set<String> {
        lock.withLock { excluded }
    }

    /// `actors` のうち、出席している人（順は、そのまま）。
    public func present(_ actors: [Actor]) -> [Actor] {
        lock.withLock { actors.filter { !excluded.contains($0.name) } }
    }
}
