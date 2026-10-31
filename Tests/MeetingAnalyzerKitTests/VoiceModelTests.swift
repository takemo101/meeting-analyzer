import CryptoKit
import Foundation
import Testing
@testable import MeetingAnalyzerKit

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func payload(_ n: Int, seed: UInt8) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }

private func configuration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return configuration
}

/// 小さな、偽のモデル（入れ子のディレクトリを持つ 3 ファイル）と、その中身。
private func fakeModel() -> (VoiceModel, [String: Data]) {
    let files: [String: Data] = [
        "Embedding.mlmodelc/coremldata.bin": payload(50, seed: 1),
        "Embedding.mlmodelc/weights/weight.bin": payload(200_000, seed: 2),
        "plda-parameters.json": payload(3_000, seed: 3),
    ]
    let model = VoiceModel(
        id: "fake", name: "fake", summary: "", repository: "o/\(UUID().uuidString)", revision: "0123456789abcdef0123",
        files: files.map { ($0.key, Int64($0.value.count), sha($0.value)) }.sorted { $0.0 < $1.0 }
    )
    return (model, files)
}

@Suite("声の分離のモデル：保管の並び・取得・消去（SPEC §3.14）", .serialized)
struct VoiceModelTests {
    @Test("一覧のモデル：FluidAudio が読む 4 つのモデルと PLDA の定数が、そろっていて、保管の場所が、版ごとの 1 つのフォルダに収まり、重複しない")
    func catalogIsComplete() throws {
        let model = try #require(VoiceModelCatalog.model(id: "speaker-separation"))
        let names = Set(model.artifacts.map(\.filename))
        for folder in ["Segmentation", "FBank", "Embedding", "PldaRho"] {
            #expect(names.contains("\(folder).mlmodelc/coremldata.bin") && names.contains("\(folder).mlmodelc/weights/weight.bin"), "\(folder) のファイルが足りない")
        }
        #expect(names.contains("plda-parameters.json"))
        #expect(Set(model.artifacts.compactMap(\.storedAs)).count == model.artifacts.count, "保管の場所が重複している")
        let prefix = "voice/\(model.revision.prefix(12))/\(model.repository.split(separator: "/").last!)/"
        for artifact in model.artifacts {
            #expect(artifact.storedAs == prefix + artifact.filename)
            #expect(artifact.sha256.count == 64 && artifact.sha256.allSatisfy { "0123456789abcdef".contains($0) })
            #expect(artifact.bytes > 0 && !artifact.filename.contains(".."))
        }
        #expect(model.revision.count == 40)
    }

    @Test("取得：ディレクトリを持つファイルを、保管の場所へ入れる（途中のディレクトリも 0700、ファイルは 0600）。全部そろってはじめて、取得済み")
    func downloadsIntoNestedFolders() async throws {
        let (model, files) = fakeModel()
        let store = ModelStore(root: tempURL("voice"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        for artifact in model.artifacts {
            let data = try #require(files[artifact.filename])
            StubProtocol.register(artifact) { _ in .init(status: 200, body: data) }
        }
        let downloader = ModelDownloader(store: store, configuration: configuration())
        // 1 つだけ取得した時点では、取得済みではない。
        try await downloader.download(model.artifacts[0]) { _, _ in }
        #expect(!store.isInstalled(model))
        for artifact in model.artifacts.dropFirst() { try await downloader.download(artifact) { _, _ in } }
        #expect(store.isInstalled(model))
        #expect(store.ensureVerified(model))

        let folder = store.folder(model).appendingPathComponent(model.repository.split(separator: "/").last.map(String.init)!)
        #expect(try Data(contentsOf: folder.appendingPathComponent("Embedding.mlmodelc/weights/weight.bin")) == files["Embedding.mlmodelc/weights/weight.bin"])
        for sub in ["", "Embedding.mlmodelc", "Embedding.mlmodelc/weights"] {
            let directory = sub.isEmpty ? folder : folder.appendingPathComponent(sub)
            #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int) == 0o700, "\(sub) は 0700")
        }
        #expect((try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("plda-parameters.json").path)[.posixPermissions] as? Int) == 0o600)
        #expect(store.downloadedBytes(model) == model.bytes)
    }

    @Test("すり替え：取得済みのファイルの中身が変わると、確認で見つけ、そのファイルを消す。モデルは、取得済みでなくなる。削除は、フォルダごと消す")
    func tamperingAndDeletion() async throws {
        let (model, files) = fakeModel()
        let store = ModelStore(root: tempURL("voice"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        for artifact in model.artifacts {
            let data = try #require(files[artifact.filename])
            StubProtocol.register(artifact) { _ in .init(status: 200, body: data) }
        }
        let downloader = ModelDownloader(store: store, configuration: configuration())
        for artifact in model.artifacts { try await downloader.download(artifact) { _, _ in } }
        let target = try #require(model.artifacts.first { $0.filename == "plda-parameters.json" })
        // 同じ大きさで、中身を変える（更新時刻も変わるので、検証済みの印が合わなくなる）。
        try Data(repeating: 7, count: Int(target.bytes)).write(to: store.fileURL(target))
        #expect(!store.isInstalled(model))
        #expect(!store.ensureVerified(model), "SHA-256 が合わないファイルは、取得済みにしない")
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(target).path), "合わなかったファイルは、消す")

        store.delete(model)
        #expect(!FileManager.default.fileExists(atPath: store.folder(model).path))
    }

    @Test("取得の順：小さいファイルから。進み具合の全体は、全ファイルの合計")
    func installPlanOrder() {
        let (model, _) = fakeModel()
        let plan = ModelInstallPlan(model)
        #expect(plan.reported.map(\.bytes) == plan.reported.map(\.bytes).sorted())
        #expect(plan.total == model.bytes && plan.quiet.isEmpty)
    }

    @Test("models download／delete：声の分離のモデルの ID を受け付ける。知らない ID は、使い方の誤り（一覧に、声の分離の ID も出る）")
    func cliAcceptsVoiceModelID() {
        #expect(CommandParser.parse(["models", "download", "speaker-separation"]) == .success(.models(.download(id: "speaker-separation"))))
        #expect(CommandParser.parse(["models", "delete", "speaker-separation"]) == .success(.models(.delete(id: "speaker-separation"))))
        guard case .failure(.usage(let message)) = CommandParser.parse(["models", "download", "nope"]) else { Issue.record("知らない ID を断らない"); return }
        #expect(message.contains("speaker-separation"))
    }
}
