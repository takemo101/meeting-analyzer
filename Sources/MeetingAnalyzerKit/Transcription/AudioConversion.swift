import AVFoundation

/// 取り込んだ音声のバッファを、認識が求める形式（`SpeechAnalyzer` の最良の形式）へ変える。
/// サンプルレートの変換は、バッファをまたいで状態を持つので、1 つの音声の流れにつき 1 つ作る。
final class AudioFormatConverter {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(target: AVAudioFormat) { self.target = target }

    /// 多チャンネルは、先頭のチャンネルだけを使う（ボイス処理後のマイクは、複数チャンネルで返ることがあるため）。
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let input = Self.firstChannel(of: buffer) ?? buffer
        if input.format == target { return input }
        if converter == nil || sourceFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
            sourceFormat = input.format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private static func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.channelCount > 1, let data = buffer.floatChannelData,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        if buffer.format.isInterleaved {
            let stride = Int(buffer.format.channelCount)
            for i in 0..<frames { dst[0][i] = data[0][i * stride] }
        } else {
            dst[0].update(from: data[0], count: frames)
        }
        out.frameLength = buffer.frameLength
        return out
    }
}

extension AVAudioPCMBuffer {
    /// 音量の目安（RMS、0〜1）。取り込みが無音でないことの確認に使う。
    public var rms: Float {
        guard let data = floatChannelData, frameLength > 0 else { return 0 }
        let n = Int(frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[0][i] * data[0][i] }
        return (sum / Float(n)).squareRoot()
    }
}
