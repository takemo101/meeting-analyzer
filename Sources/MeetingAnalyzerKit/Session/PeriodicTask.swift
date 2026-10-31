import Foundation

/// 一定の間隔で、取り消されるまで、`action` を繰り返す（先に待ち、待ったあとで取り消されていたら、実行せずに終わる）。
/// 会議の tick（`LiveSession`）と、画面の定期の撮影（`ScreenRecorder`）が使う。止めるときは、返した `Task` を `cancel()` する。
func repeatEvery(_ interval: Duration, _ action: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { break }
            await action()
        }
    }
}
