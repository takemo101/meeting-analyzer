import AVFoundation
import Foundation

/// 声の分離（SPEC §3.14）のために、システム音声を、**メモリ上だけ**に持つ（16 kHz・モノラル・16 bit。1 時間 約 115 MB）。
/// **ファイル・ネットワークへは出さない。** 取り込みの塊（一時停止ごと）に分けて持ち、会議の時刻（開始からの秒）との対応（`AudioTimeline`）を添える。
/// 長すぎる会議は、上限（3 時間）を超えた分を持たない（`isTruncated`）。`append` はオーディオのスレッドから呼ばれるので、ロックで守る。
public final class VoiceAudioRecorder: @unchecked Sendable {
    public static let sampleRate = 16_000.0
    /// 持てる上限（秒）。
    public static let maxSeconds = 3 * 3600

    private struct Piece {
        var origin: TimeInterval?
        var samples: [Int16] = []
    }

    private let lock = NSLock()
    private var pieces: [Piece] = []
    private var total = 0
    private var truncated = false
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private let limit: Int

    /// `maxSamples`：試験で、上限を小さくするために差し替える。
    public init(maxSamples: Int = maxSeconds * Int(sampleRate)) { limit = maxSamples }

    /// 取り込みの塊を始める（開始・再開のとき）。
    public func begin() {
        lock.lock(); defer { lock.unlock() }
        pieces.append(Piece())
        converter = nil
        converterInput = nil
    }

    /// いちばん新しい塊の最初の音の、会議の時刻（秒）。
    public func setOrigin(_ origin: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard !pieces.isEmpty else { return }
        pieces[pieces.count - 1].origin = origin
    }

    /// 音を足す（形式が違えば、16 kHz・モノラル・16 bit に変える）。上限を超える分は、捨てる。
    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !pieces.isEmpty, buffer.frameLength > 0, total < limit else {
            if total >= limit { truncated = true }
            return
        }
        if converter == nil || converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converterInput = buffer.format
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let data = out.int16ChannelData else { return }
        let count = min(Int(out.frameLength), limit - total)
        pieces[pieces.count - 1].samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
        total += count
        if count < Int(out.frameLength) { truncated = true }
    }

    /// 上限を超えて、捨てた音があるか。
    public var isTruncated: Bool { lock.lock(); defer { lock.unlock() }; return truncated }

    /// 持っている音声の長さ（秒）。
    public var seconds: TimeInterval { lock.lock(); defer { lock.unlock() }; return TimeInterval(total) / Self.sampleRate }

    /// 分離に渡す音声（つなげた Float。-1〜1）と、会議の時刻との対応。時刻が分からない塊・空の塊は、除く。何も無ければ `nil`。
    public func snapshot() -> (samples: [Float], timeline: AudioTimeline)? {
        lock.lock(); defer { lock.unlock() }
        let usable = pieces.filter { $0.origin != nil && !$0.samples.isEmpty }
        guard !usable.isEmpty else { return nil }
        var floats: [Float] = []
        floats.reserveCapacity(usable.reduce(0) { $0 + $1.samples.count })
        for piece in usable { floats.append(contentsOf: piece.samples.lazy.map { Float($0) / 32768 }) }
        let timeline = AudioTimeline(pieces: usable.map { AudioTimeline.Piece(origin: $0.origin ?? 0, duration: TimeInterval($0.samples.count) / Self.sampleRate) })
        return (floats, timeline)
    }

    /// 音声を捨てる（分離のあと・取り消し・失敗のとき）。
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        pieces = []
        total = 0
        truncated = false
        converter = nil
        converterInput = nil
    }
}
