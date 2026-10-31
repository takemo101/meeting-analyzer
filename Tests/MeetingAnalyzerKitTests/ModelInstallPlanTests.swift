import Foundation
import Testing
@testable import MeetingAnalyzerKit

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var fetched: [String] = []
    private var reported: [[Int64]] = []

    func fetch(_ artifact: ModelArtifact) { lock.withLock { fetched.append(artifact.filename) } }
    func report(_ received: Int64, _ total: Int64) { lock.withLock { reported.append([received, total]) } }
    var fetchedFiles: [String] { lock.withLock { fetched } }
    var reports: [[Int64]] { lock.withLock { reported } }
}

@Suite("ModelInstallPlan: 取得物を順に取り、進み具合を、全体の合計に対して報告する")
struct ModelInstallPlanTests {
    /// 取得物ごとに、半分・全部、と報告する偽の取得。
    private func fetch(_ recorder: Recorder) -> ModelInstallPlan.Fetch {
        { artifact, progress in
            recorder.fetch(artifact)
            progress(artifact.bytes / 2, artifact.bytes)
            progress(artifact.bytes, artifact.bytes)
        }
    }

    @Test("判断モデルは、トークナイザ → 重みの順。進み具合は、2 つの合計に対する取得済み（取得物をまたいで、増え続ける）")
    func decisionModel() async throws {
        let model = try #require(DecisionModelCatalog.all.first)
        let recorder = Recorder()
        try await ModelInstallPlan(model).run(fetch: fetch(recorder)) { recorder.report($0, $1) }
        #expect(recorder.fetchedFiles == [model.tokenizer.filename, model.weights.filename])
        let tokenizer = model.tokenizer.bytes
        #expect(recorder.reports == [
            [tokenizer / 2, model.bytes], [tokenizer, model.bytes],
            [tokenizer + model.weights.bytes / 2, model.bytes], [model.bytes, model.bytes],
        ])
    }

    @Test("文字起こしのモデルは、音声区間の検出のモデル（小さい）を先に取り、その分は、進み具合に含めない。進み具合は、本体だけ")
    func localModel() async throws {
        let model = try #require(LocalModelCatalog.all.first)
        let recorder = Recorder()
        try await ModelInstallPlan(model).run(fetch: fetch(recorder)) { recorder.report($0, $1) }
        #expect(recorder.fetchedFiles == [LocalModelCatalog.voiceActivity.filename, model.artifact.filename])
        #expect(recorder.reports == [[model.artifact.bytes / 2, model.artifact.bytes], [model.artifact.bytes, model.artifact.bytes]])
    }

    @Test("途中で失敗したら、そこで止まり、あとの取得物は取らない")
    func stopsAtFailure() async throws {
        let model = try #require(DecisionModelCatalog.all.first)
        let recorder = Recorder()
        await #expect(throws: ModelDownloadError.cancelled) {
            try await ModelInstallPlan(model).run(fetch: { artifact, _ in recorder.fetch(artifact); throw ModelDownloadError.cancelled }) { recorder.report($0, $1) }
        }
        #expect(recorder.fetchedFiles == [model.tokenizer.filename])
    }
}
