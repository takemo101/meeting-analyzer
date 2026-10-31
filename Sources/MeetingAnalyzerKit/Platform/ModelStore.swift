import CryptoKit
import Foundation

/// ダウンロードしたモデルの保管場所と、検証（SPEC §3.12）。`<データの置き場所>/models/`。ディレクトリ 0700・ファイル 0600。
/// **記録の保持期間では、消さない**（モデルは、利用者が選んで取得したもの。消すのは、利用者が「削除」を選んだときだけ）。
/// ファイル名に、SHA-256 の先頭を入れる＝固定した版（`ModelArtifact`）を変えたら、別のファイルとして、取得し直す。
public struct ModelStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var directory: URL { root.appendingPathComponent("models", isDirectory: true) }

    public func fileURL(_ artifact: ModelArtifact) -> URL {
        directory.appendingPathComponent(artifact.storedAs ?? "\(artifact.sha256.prefix(12))-\(artifact.filename)")
    }

    /// ダウンロード途中のファイル（続きから再開できる）。
    public func partURL(_ artifact: ModelArtifact) -> URL { fileURL(artifact).appendingPathExtension("part") }

    /// 検証済みの印（大きさ・更新時刻）。毎回、SHA-256 を計算し直さずに、すり替えを検出するため。
    private func receiptURL(_ artifact: ModelArtifact) -> URL { fileURL(artifact).appendingPathExtension("verified") }

    private struct Receipt: Codable, Equatable {
        let bytes: Int64
        let modified: Double
    }

    private func attributes(_ url: URL) -> (bytes: Int64, modified: Double)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path), let size = a[.size] as? NSNumber, let date = a[.modificationDate] as? Date else { return nil }
        return (size.int64Value, date.timeIntervalSince1970)
    }

    /// 取得して、検証を済ませたか（大きさが固定した値と一致し、検証済みの印と、更新時刻が合う）。SHA-256 の計算はしない。
    public func isInstalled(_ artifact: ModelArtifact) -> Bool {
        guard let now = attributes(fileURL(artifact)), now.bytes == artifact.bytes,
              let data = try? Data(contentsOf: receiptURL(artifact)), let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return false }
        return receipt == Receipt(bytes: now.bytes, modified: now.modified)
    }

    /// 取得済みのバイト数（ダウンロード途中を含む。進み具合の表示用）。
    public func downloadedBytes(_ artifact: ModelArtifact) -> Int64 {
        if isInstalled(artifact) { return artifact.bytes }
        return attributes(partURL(artifact))?.bytes ?? 0
    }

    /// SHA-256（16 進、小文字）。大きいファイルなので、少しずつ読む。
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 使う前の確認。検証済みの印が合えば、すぐ返す。印が無い・合わない（すり替え・コピー）ときは、SHA-256 を計算して確かめ、合えば印を付け直す。
    /// 合わなければ、ファイルを消して `false`。
    public func ensureVerified(_ artifact: ModelArtifact) -> Bool {
        if isInstalled(artifact) { return true }
        let url = fileURL(artifact)
        guard let now = attributes(url), now.bytes == artifact.bytes else { return false }
        guard let sum = try? Self.sha256(of: url), sum == artifact.sha256 else {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: receiptURL(artifact))
            return false
        }
        markVerified(artifact)
        return true
    }

    /// 取得した（または、確かめた）ファイルに、検証済みの印を付ける。
    func markVerified(_ artifact: ModelArtifact) {
        let url = fileURL(artifact)
        guard let now = attributes(url), let data = try? JSONEncoder().encode(Receipt(bytes: now.bytes, modified: now.modified)) else { return }
        try? data.write(to: receiptURL(artifact), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL(artifact).path)
    }

    /// 保管場所（0700）を用意する。
    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// ファイルの置き場所（`storedAs` の途中のディレクトリ）を、0700 で用意する。
    func prepareParent(of artifact: ModelArtifact) throws {
        try prepareDirectory()
        let parent = fileURL(artifact).deletingLastPathComponent()
        guard parent.standardizedFileURL != directory.standardizedFileURL else { return }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var current = parent
        while current.standardizedFileURL != directory.standardizedFileURL, current.path.count > directory.path.count {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: current.path)
            current.deleteLastPathComponent()
        }
    }

    /// 途中のファイル（`.part`）だけを、消す。取得済みのファイルには、触れない。
    public func discardPartial(_ artifact: ModelArtifact) {
        try? FileManager.default.removeItem(at: partURL(artifact))
    }

    /// モデルのファイル・途中のファイル・印を、消す。
    public func delete(_ artifact: ModelArtifact) {
        for url in [fileURL(artifact), partURL(artifact), receiptURL(artifact)] { try? FileManager.default.removeItem(at: url) }
    }
}

/// 判断モデル（重み＋トークナイザの 2 ファイル。`DecisionModel`）。すべてのファイルが、そろってはじめて「取得済み」。
extension ModelStore {
    public func isInstalled(_ model: DecisionModel) -> Bool { model.artifacts.allSatisfy(isInstalled) }

    /// 取得済みのバイト数（途中を含む）。
    public func downloadedBytes(_ model: DecisionModel) -> Int64 { model.artifacts.reduce(0) { $0 + downloadedBytes($1) } }

    /// 途中のファイルだけを消す（取得済みのファイルには、触れない）。
    public func discardPartial(_ model: DecisionModel) { model.artifacts.forEach(discardPartial) }

    /// 重みを消す。トークナイザは、**同じファイル（SHA-256 が同じ）を使う、ほかの取得済みの判断モデルがあれば、残す**。
    public func delete(_ model: DecisionModel) {
        delete(model.weights)
        let shared = DecisionModelCatalog.all.contains { other in
            other.id != model.id && other.tokenizer.sha256 == model.tokenizer.sha256 && isInstalled(other.weights)
        }
        if !shared { delete(model.tokenizer) }
    }
}

/// 声の分離のモデル（複数のファイル。`VoiceModel`）。すべてのファイルが、そろってはじめて「取得済み」。
extension ModelStore {
    public func isInstalled(_ model: VoiceModel) -> Bool { model.artifacts.allSatisfy(isInstalled) }

    /// 取得済みのバイト数（途中を含む）。
    public func downloadedBytes(_ model: VoiceModel) -> Int64 { model.artifacts.reduce(0) { $0 + downloadedBytes($1) } }

    /// 途中のファイルだけを消す（取得済みのファイルには、触れない）。
    public func discardPartial(_ model: VoiceModel) { model.artifacts.forEach(discardPartial) }

    /// FluidAudio へ渡す、モデルの置き場所（この下に、`<リポジトリの名前>/` がある）。
    public func folder(_ model: VoiceModel) -> URL { directory.appendingPathComponent(model.storageFolder, isDirectory: true) }

    /// 使う前の確認（すべてのファイルで、検証済みの印・SHA-256 を確かめる）。1 つでも合わなければ、そのファイルを消して `false`。
    public func ensureVerified(_ model: VoiceModel) -> Bool {
        var ok = true
        for artifact in model.artifacts where !ensureVerified(artifact) { ok = false }
        return ok
    }

    /// このモデルの置き場所を、まるごと消す（途中のファイル・印を含む）。
    public func delete(_ model: VoiceModel) {
        try? FileManager.default.removeItem(at: folder(model))
    }
}
