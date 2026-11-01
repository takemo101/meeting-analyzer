import AVFoundation
import Foundation

public enum SavedAudioError: Error, Sendable, Equatable {
    case writeFailed(String)
    /// 保存した音声が、この会議に無い（保存しなかった・保持期間で消えた・削除した）。
    case missing
    /// 保存した音声を読めない（壊れている・時刻の対応と合わない）。
    case unreadable(String)

    public var message: String {
        switch self {
        case .writeFailed(let reason): return "相手の音声を保存できませんでした（\(reason)）"
        case .missing: return "この会議の音声が、保存されていません（保存しなかった、または、保持期間で消えました）"
        case .unreadable(let reason): return "保存した音声を読めません（\(reason)）"
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

/// あとから名付けできる会議 1 件（音声と、名付けの写しが、そろっている会議。SPEC §3.16）。
public struct PastMeeting: Sendable, Equatable, Identifiable {
    public let sessionId: UUID
    public let title: String
    public let startedAt: Date
    public let endedAt: Date
    /// 声で分けた話者の数（話者 N の種類）と、そのうち名前が確定している数。
    public let speakers: Int
    public let named: Int

    public var id: UUID { sessionId }

    public init(sessionId: UUID, title: String, startedAt: Date, endedAt: Date, speakers: Int, named: Int) {
        self.sessionId = sessionId
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.speakers = speakers
        self.named = named
    }
}

/// 相手（システム音声）の音声の保存（SPEC §3.16）。**利用者が「相手の音声を保存する」を選んだときだけ**使う。
/// `<root>/sessions/<sessionId>/others.wav`（16 kHz・モノラル・16 bit の WAV）と、会議の時刻との対応 `others.json`（塊ごとの、最初の音の会議の時刻と長さ）を、
/// 利用者だけが読める権限（ディレクトリ 0700・ファイル 0600）で置く。記録と同じフォルダなので、**記録と同じ寿命で消える**（`RecordRetention`）。
/// 音声のパス・中身は、ログ・記録・エージェントへ出さない。
public struct SavedAudioStore: Sendable {
    public static let audioName = "others.wav"
    public static let timelineName = "others.json"
    public static let snapshotName = "speakers.json"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func directory(sessionId: UUID) -> URL {
        root.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(sessionId.uuidString.lowercased(), isDirectory: true)
    }

    public func audioURL(sessionId: UUID) -> URL { directory(sessionId: sessionId).appendingPathComponent(Self.audioName) }
    public func timelineURL(sessionId: UUID) -> URL { directory(sessionId: sessionId).appendingPathComponent(Self.timelineName) }
    public func snapshotURL(sessionId: UUID) -> URL { directory(sessionId: sessionId).appendingPathComponent(Self.snapshotName) }

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

    /// この会議の音声が、保存されているか。
    public func exists(sessionId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(sessionId: sessionId).path) && FileManager.default.fileExists(atPath: timelineURL(sessionId: sessionId).path)
    }

    /// 会議の時刻との対応だけを読む（聞き直しのため。音声は読まない）。
    public func timeline(sessionId: UUID) -> Result<AudioTimeline, SavedAudioError> {
        guard exists(sessionId: sessionId) else { return .failure(.missing) }
        guard let stored = try? JSONDecoder().decode(StoredTimeline.self, from: Data(contentsOf: timelineURL(sessionId: sessionId))) else { return .failure(.unreadable("時刻の対応を読めません")) }
        return .success(AudioTimeline(pieces: stored.pieces.map { .init(origin: $0.origin, duration: $0.duration) }))
    }

    /// 保存した音声（つなげた Float。-1〜1）と、会議の時刻との対応を読む（再分離のため。SPEC §3.16）。
    /// 長さが、時刻の対応の合計と 1 秒以上ずれていれば、壊れているとみなす。
    public func load(sessionId: UUID) -> Result<(samples: [Float], timeline: AudioTimeline), SavedAudioError> {
        guard exists(sessionId: sessionId) else { return .failure(.missing) }
        do {
            let stored = try JSONDecoder().decode(StoredTimeline.self, from: Data(contentsOf: timelineURL(sessionId: sessionId)))
            let timeline = AudioTimeline(pieces: stored.pieces.map { .init(origin: $0.origin, duration: $0.duration) })
            let file = try AVAudioFile(forReading: audioURL(sessionId: sessionId))
            guard file.fileFormat.sampleRate == VoiceAudioRecorder.sampleRate, file.fileFormat.channelCount == 1 else { return .failure(.unreadable("形式が違います")) }
            let frames = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return .failure(.unreadable("メモリを確保できません")) }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { return .failure(.unreadable("形式が違います")) }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let expected = timeline.pieces.reduce(0) { $0 + $1.duration }
            guard abs(Double(samples.count) / VoiceAudioRecorder.sampleRate - expected) < 1 else { return .failure(.unreadable("長さが、時刻の対応と合いません")) }
            return .success((samples, timeline))
        } catch {
            return .failure(.unreadable("ファイルを読めません"))
        }
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
            try? manager.removeItem(at: directory.appendingPathComponent(Self.snapshotName))
            try? manager.removeItem(at: directory.appendingPathComponent(Self.audioName + ".part"))
            if let modified { try? manager.setAttributes([.modificationDate: modified], ofItemAtPath: directory.path) }
        }
        return removed
    }

    // MARK: あとからの名付けの写し（SPEC §3.16）

    /// 名付けの写しを書く（`speakers.json`。0600。書きかけを残さない）。書けなければ `false`（あとからの名付けが、できないだけ。会議の終了は止めない）。
    @discardableResult
    public func writeSnapshot(_ snapshot: SessionSnapshot, sessionId: UUID) -> Bool {
        let manager = FileManager.default
        let directory = directory(sessionId: sessionId)
        let file = snapshotURL(sessionId: sessionId)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            return false
        }
    }

    /// 名付けの写しを読む。音声が無い・写しが無い・読めない・知らない版のときは、理由を返す。
    public func readSnapshot(sessionId: UUID) -> Result<SessionSnapshot, SavedAudioError> {
        guard exists(sessionId: sessionId), FileManager.default.fileExists(atPath: snapshotURL(sessionId: sessionId).path) else { return .failure(.missing) }
        guard let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: snapshotURL(sessionId: sessionId))) else { return .failure(.unreadable("名付けの写しを読めません")) }
        guard snapshot.version == SessionSnapshot.currentVersion, snapshot.sessionId == sessionId.uuidString.lowercased() else { return .failure(.unreadable("名付けの写しの版が違います")) }
        return .success(snapshot)
    }

    /// あとから名付けできる会議の一覧（新しい順）。音声と写しが、そろっていて、読めるものだけ。
    public func pastMeetings() -> [PastMeeting] {
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        var result: [PastMeeting] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? [] {
            guard let id = UUID(uuidString: name), case .success(let snapshot) = readSnapshot(sessionId: id) else { continue }
            let kinds = Set(snapshot.utterances.compactMap { $0.speaker == Speaker.others.rawValue && $0.isFinal ? $0.voice : nil })
            let named = kinds.filter { snapshot.voiceNames[String($0)] != nil }.count
            result.append(PastMeeting(sessionId: id, title: snapshot.title, startedAt: snapshot.startedDate, endedAt: snapshot.endedDate, speakers: kinds.count, named: named))
        }
        return result.sorted { $0.startedAt > $1.startedAt }
    }
}
