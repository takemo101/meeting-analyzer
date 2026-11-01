import Foundation

public enum SavedAudioError: Error, Sendable, Equatable {
    case writeFailed(String)

    public var message: String {
        switch self {
        case .writeFailed(let reason): return "相手の音声を保存できませんでした（\(reason)）"
        }
    }
}

/// 保存した相手の音声の、件数と大きさ（設定ウィンドウに見せる）。
public struct SavedAudioSummary: Sendable, Equatable {
    public var count = 0
    public var bytes: Int64 = 0

    public init(count: Int = 0, bytes: Int64 = 0) {
        self.count = count
        self.bytes = bytes
    }
}

/// 相手（システム音声）の音声の保存（SPEC §3.16）。**利用者が「相手の音声を保存する」を選んだときだけ**使う。
/// `<root>/sessions/<sessionId>/others.wav`（16 kHz・モノラル・16 bit の WAV）と、会議の時刻との対応 `others.json`（塊ごとの、最初の音の会議の時刻と長さ）を、
/// 利用者だけが読める権限（ディレクトリ 0700・ファイル 0600）で置く。記録と同じフォルダなので、**記録と同じ寿命で消える**（`RecordRetention`）。
/// 音声のパス・中身は、ログ・記録・エージェントへ出さない。
public struct SavedAudioStore: Sendable {
    public static let audioName = "others.wav"
    public static let timelineName = "others.json"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func directory(sessionId: UUID) -> URL {
        root.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(sessionId.uuidString.lowercased(), isDirectory: true)
    }

    public func audioURL(sessionId: UUID) -> URL { directory(sessionId: sessionId).appendingPathComponent(Self.audioName) }
    public func timelineURL(sessionId: UUID) -> URL { directory(sessionId: sessionId).appendingPathComponent(Self.timelineName) }

    private struct StoredTimeline: Codable {
        struct Piece: Codable { var origin: TimeInterval; var duration: TimeInterval }
        var sampleRate: Int
        var pieces: [Piece]
    }

    /// 音声（つなげた Float。-1〜1）を、WAV で保存する。**途中で失敗したら、書きかけを残さない**（時刻の対応を先に書き、WAV は、最後に、名前を付けて置く）。
    public func save(samples: [Float], timeline: AudioTimeline, sessionId: UUID) -> Result<Void, SavedAudioError> {
        let directory = directory(sessionId: sessionId)
        let manager = FileManager.default
        let audio = audioURL(sessionId: sessionId), timelineFile = timelineURL(sessionId: sessionId)
        let part = directory.appendingPathComponent(Self.audioName + ".part")
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let stored = StoredTimeline(sampleRate: Int(VoiceAudioRecorder.sampleRate), pieces: timeline.pieces.map { .init(origin: $0.origin, duration: $0.duration) })
            try JSONEncoder().encode(stored).write(to: timelineFile, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: timelineFile.path)

            guard manager.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            try handle.write(contentsOf: Self.wavHeader(sampleCount: samples.count))
            let chunk = 1 << 16
            var index = 0
            while index < samples.count {
                let end = min(index + chunk, samples.count)
                var data = Data(capacity: (end - index) * 2)
                for value in samples[index..<end] {
                    let scaled = (value * 32768).rounded()
                    let sample = Int16(max(-32768, min(32767, scaled)))
                    withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
                }
                try handle.write(contentsOf: data)
                index = end
            }
            try handle.close()
            if manager.fileExists(atPath: audio.path) { try manager.removeItem(at: audio) }
            try manager.moveItem(at: part, to: audio)
            return .success(())
        } catch {
            try? manager.removeItem(at: part)
            try? manager.removeItem(at: timelineFile)
            try? manager.removeItem(at: audio)
            return .failure(.writeFailed((error as? CocoaError).map { "ファイルを書けません: \($0.code.rawValue)" } ?? "ファイルを書けません"))
        }
    }

    /// 16 kHz・モノラル・16 bit の PCM の WAV ヘッダ（44 バイト）。
    static func wavHeader(sampleCount: Int) -> Data {
        let dataBytes = UInt32(truncatingIfNeeded: sampleCount * 2)
        var header = Data()
        func text(_ value: String) { header.append(contentsOf: Array(value.utf8)) }
        func int32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func int16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        text("RIFF"); int32(36 &+ dataBytes); text("WAVE")
        text("fmt "); int32(16); int16(1); int16(1); int32(16_000); int32(32_000); int16(2); int16(16)
        text("data"); int32(dataBytes)
        return header
    }

    /// 保存した音声の、件数と大きさ。
    public func summary() -> SavedAudioSummary {
        var result = SavedAudioSummary()
        let manager = FileManager.default
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        for name in (try? manager.contentsOfDirectory(atPath: sessions.path)) ?? [] {
            let file = sessions.appendingPathComponent(name, isDirectory: true).appendingPathComponent(Self.audioName)
            guard let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? NSNumber else { continue }
            result.count += 1
            result.bytes += size.int64Value
        }
        return result
    }

    /// 保存した音声を、すべて消す（記録・声紋は残す）。消した件数を返す。**記録の保持期間の起点を動かさない**（ディレクトリの更新時刻を、戻す）。
    @discardableResult
    public func deleteAll() -> Int {
        var removed = 0
        let manager = FileManager.default
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        for name in (try? manager.contentsOfDirectory(atPath: sessions.path)) ?? [] {
            let directory = sessions.appendingPathComponent(name, isDirectory: true)
            let audio = directory.appendingPathComponent(Self.audioName)
            guard manager.fileExists(atPath: audio.path) else { continue }
            let modified = (try? manager.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date
            if (try? manager.removeItem(at: audio)) != nil { removed += 1 }
            try? manager.removeItem(at: directory.appendingPathComponent(Self.timelineName))
            try? manager.removeItem(at: directory.appendingPathComponent(Self.audioName + ".part"))
            if let modified { try? manager.setAttributes([.modificationDate: modified], ofItemAtPath: directory.path) }
        }
        return removed
    }
}
