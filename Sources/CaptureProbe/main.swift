// 取り込みの試作（実験用。製品の CLI ではない）。マイク／システム音声を、オンデバイスで文字にし、遅延と音量を測って標準出力へ出す。
// 音声は保存・送信しない。権限は、--request を付けたときだけ OS に要求する（付けなければ、許可済みでないと止まる）。
// 出力には会議の本文が含まれうる。検証の記録へは貼らない。
import AVFoundation
import Foundation
import MeetingAnalyzerKit

struct Options {
    var mic = false
    var apps: [String] = []
    var listApps = false
    var file: String?
    var request = false
    var seconds = 30.0
    var locale = "ja_JP"
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func parse() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())[...]
    while let a = args.popFirst() {
        switch a {
        case "--mic": o.mic = true
        case "--list-apps": o.listApps = true
        case "--request": o.request = true
        case "--file": guard let v = args.popFirst() else { fail("--file にパスが要ります") }; o.file = v
        case "--app": guard let v = args.popFirst() else { fail("--app に bundle ID が要ります") }; o.apps.append(v)
        case "--seconds": guard let v = args.popFirst(), let s = Double(v), s > 0 else { fail("--seconds に正の数が要ります") }; o.seconds = s
        case "--locale": guard let v = args.popFirst() else { fail("--locale に値が要ります") }; o.locale = v
        default: fail("""
            使い方: CaptureProbe [--file <音声>] [--mic] [--app <bundleID>]... [--list-apps] [--seconds N] [--locale L] [--request]
            --request なしでは、マイク・画面収録が許可済みのときだけ動く（権限の要求をしない）。
            """)
        }
    }
    if !o.mic && o.apps.isEmpty && !o.listApps && o.file == nil { fail("--file、--mic、--app、--list-apps のどれかが要ります") }
    return o
}

let options = parse()
let locale = Locale(identifier: options.locale)
let clock = ContinuousClock()
let origin = clock.now
func elapsed() -> Double {
    let d = origin.duration(to: clock.now)
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}
func out(_ line: String) { print(String(format: "%7.2f ", elapsed()) + line); fflush(stdout) }

let needsScreen = options.listApps || !options.apps.isEmpty
if !options.request {
    if options.mic && !MicrophoneCapture.isAuthorized { fail("マイクが未許可です。この実行ファイルを起動したプロセスに許可が要ります。利用者が --request で実行してください。") }
    if needsScreen && !ScreenRecordingPermission.isGranted { fail("画面収録が未許可です。この実行ファイルを起動したプロセスに許可が要ります。利用者が --request で実行してください。") }
}

if options.listApps {
    do { for app in try await SystemAudioCapture.availableApps() { print("\(app.bundleID)\t\(app.name)") } }
    catch { fail("\(error)") }
    if !options.mic && options.apps.isEmpty { exit(0) }
}

struct Stats { var buffers = 0; var peak: Float = 0; var updates = 0; var finals = 0; var lagSum = 0.0; var lagMax = 0.0 }
actor Report {
    var stats: [String: Stats] = [:]
    func buffer(_ name: String, rms: Float) { stats[name, default: Stats()].buffers += 1; stats[name, default: Stats()].peak = max(stats[name, default: Stats()].peak, rms) }
    func update(_ name: String, lag: Double, final: Bool) {
        var s = stats[name, default: Stats()]
        s.updates += 1; if final { s.finals += 1; s.lagSum += lag; s.lagMax = max(s.lagMax, lag) }
        stats[name] = s
    }
}
let report = Report()
let transcriber = AppleSpeechTranscriber()

/// 1 つの音声の流れを、音量の測定 → 認識 → 出力へ流す。lag = 実時間の経過 − 認識が指す音声の終端（確定した結果だけ集計）。
func run(name: String, buffers: AsyncStream<AVAudioPCMBuffer>) -> Task<Void, Never> {
    let (tapped, tap) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
    let startedAt = elapsed()
    Task { for await b in buffers { await report.buffer(name, rms: b.rms); tap.yield(b) }; tap.finish() }
    return Task {
        do {
            for try await u in transcriber.updates(forLive: tapped, locale: locale) {
                let lag = (elapsed() - startedAt) - u.end
                await report.update(name, lag: lag, final: u.isFinal)
                out("[\(name)] \(u.isFinal ? "確定" : "暫定") lag=\(String(format: "%.2f", lag))s  \(u.text)")
            }
        } catch { out("[\(name)] 認識の失敗: \(error)") }
    }
}

/// 音声ファイルを、ライブ入力として実時間で流す（権限なしで、ライブ認識の経路と遅延を確かめる）。
func fileBuffers(_ path: String) -> AsyncStream<AVAudioPCMBuffer> {
    AsyncStream { continuation in
        Task.detached {
            guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { continuation.finish(); return }
            let ms = Int(ProcessInfo.processInfo.environment["PROBE_CHUNK_MS"] ?? "100") ?? 100
            let chunk = AVAudioFrameCount(file.processingFormat.sampleRate * Double(ms) / 1000)
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk), (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 else { break }
                continuation.yield(buffer)
                try? await Task.sleep(for: .milliseconds(ms))
            }
            // 話が終わったあとの無音（実際の会議では、話の後も入力が続く）。
            let tail = Int(ProcessInfo.processInfo.environment["PROBE_TAIL_SECONDS"] ?? "0") ?? 0
            for _ in 0..<(tail * 10) {
                guard let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
                silence.frameLength = chunk
                continuation.yield(silence)
                try? await Task.sleep(for: .milliseconds(100))
            }
            continuation.finish()
        }
    }
}

var tasks: [Task<Void, Never>] = []
let mic = MicrophoneCapture()
let system = SystemAudioCapture()
if let path = options.file { tasks.append(run(name: "file", buffers: fileBuffers(path))); out("ファイルを実時間で流す") }
do {
    if options.mic { tasks.append(run(name: "you", buffers: try await mic.start())); out("マイク（ボイス処理）を開始") }
    if !options.apps.isEmpty { tasks.append(run(name: "others", buffers: try await system.start(bundleIDs: options.apps))); out("システム音声を開始: \(options.apps.joined(separator: ", "))") }
} catch {
    mic.stop(); await system.stop()
    fail("取り込みを始められません: \(error)")
}

if options.file != nil && !options.mic && options.apps.isEmpty {
    for t in tasks { await t.value }
} else {
    try? await Task.sleep(for: .seconds(options.seconds))
}
mic.stop(); await system.stop()
for t in tasks { await t.value }

print("--- まとめ（本文は含まない）")
for (name, s) in await report.stats.sorted(by: { $0.key < $1.key }) {
    let avg = s.finals > 0 ? s.lagSum / Double(s.finals) : .nan
    print(String(format: "%@: バッファ %d、最大 RMS %.4f、更新 %d（確定 %d）、確定の遅延 平均 %.2fs 最大 %.2fs", name, s.buffers, s.peak, s.updates, s.finals, avg, s.lagMax))
}
