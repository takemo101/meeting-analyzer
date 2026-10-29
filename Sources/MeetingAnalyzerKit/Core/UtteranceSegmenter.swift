/// 発話の区切り（SPEC §3.12）：音声区間の検出（VAD）が返す、フレームごとの「声である確率」から、1 つの発話の範囲を決める。
/// ダウンロードしたモデルは、ストリーミングに対応しない（暫定の文字を出せない）ので、**発話が終わったと判断した時点で、その発話を 1 回で文字にする**。
/// 時計・音声を持たない、純粋な規則（フレーム番号だけを扱う）。1 フレームは `frameSamples`（512）サンプル＝16 kHz で 32 ms。
public struct UtteranceSegmenter: Sendable {
    public static let frameSamples = 512
    public static let sampleRate = 16_000

    public struct Parameters: Sendable, Equatable {
        /// この確率以上のフレームで、発話が始まる。
        public var startThreshold: Float = 0.5
        /// 発話の途中で、この確率を下回ったフレームを、無音とみなす（始まりより低くして、語の途中の揺れで切れないようにする）。
        public var releaseThreshold: Float = 0.35
        /// これより短い発話は、捨てる（咳・クリックなど）。約 0.26 秒。
        public var minSpeechFrames = 8
        /// 無音がこの長さ続いたら、発話が終わったとする。約 0.7 秒（文の途中の短い間では、切らない）。
        public var endSilenceFrames = 22
        /// 発話の前後に足す余白。約 0.19 秒（語頭・語尾が欠けないように）。
        public var padFrames = 6
        /// これより長い発話は、そこで区切る。約 30 秒（モデルが 1 回で扱える長さの安全な範囲）。
        public var maxFrames = 937

        public init() {}
    }

    /// 発話の範囲。フレーム番号で、`[startFrame, endFrame)`。余白を含む。`endFrame` は、実際の音声の長さを超えうる（呼び出し側が丸める）。
    public struct Segment: Sendable, Equatable {
        public let startFrame: Int
        public let endFrame: Int
    }

    public let parameters: Parameters
    /// 次に受け取るフレームの番号。
    private var frame = 0
    private var inSpeech = false
    private var speechStart = 0
    private var lastSpeech = 0
    private var speechFrames = 0
    private var silentRun = 0
    /// いまの発話の前に足す余白。強制的に区切った続きは、前の発話の終わりと重ならないよう、0。
    private var startPad = 0

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// 次のフレームの確率を、順に渡す。発話が終わった（または長すぎた）なら、その範囲を返す。何度に分けて渡しても、結果は同じ。
    public mutating func push(_ probabilities: [Float]) -> [Segment] {
        var segments: [Segment] = []
        for p in probabilities {
            let f = frame
            frame += 1
            if !inSpeech {
                guard p >= parameters.startThreshold else { continue }
                inSpeech = true
                speechStart = f
                lastSpeech = f
                speechFrames = 1
                silentRun = 0
                startPad = parameters.padFrames
                continue
            }
            if p >= parameters.releaseThreshold {
                lastSpeech = f
                speechFrames += 1
                silentRun = 0
            } else {
                silentRun += 1
                if silentRun >= parameters.endSilenceFrames {
                    if let segment = close(end: lastSpeech + 1 + parameters.padFrames) { segments.append(segment) }
                    inSpeech = false
                    continue
                }
            }
            // 長すぎる発話は、そこで区切り、続きは、新しい発話として始める。
            if f + 1 - speechStart >= parameters.maxFrames {
                if let segment = close(end: f + 1) { segments.append(segment) }
                speechStart = f + 1
                lastSpeech = f
                speechFrames = 0
                silentRun = 0
                startPad = 0
            }
        }
        return segments
    }

    /// 入力が終わった。発話の途中なら、そこまでを、発話として返す。
    public mutating func flush() -> [Segment] {
        defer { inSpeech = false }
        guard inSpeech, let segment = close(end: lastSpeech + 1 + parameters.padFrames) else { return [] }
        return [segment]
    }

    private func close(end: Int) -> Segment? {
        guard speechFrames >= parameters.minSpeechFrames else { return nil }
        return Segment(startFrame: max(0, speechStart - startPad), endFrame: end)
    }
}
