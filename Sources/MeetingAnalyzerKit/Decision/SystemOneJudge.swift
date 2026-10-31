import Foundation

/// ダウンロードした System One 型の判断モデルで、`SpeakerJudge` の問いに答える（SPEC §3.13）。確率（確信度）を返す。
/// 会議の間だけ、モデルを読み込む（GPU のメモリに、重みの約 1.2 GB。会議が終わって、これを手放すと、解放される）。
/// 入力が違うモデルでも、同じ呼び方になるよう、系統ごとの実装（いまは `QwenDecision`）を、ここで選ぶ。
public final class SystemOneJudge: SpeakerJudge, @unchecked Sendable {
    /// 入力の長さの段（トークン）。グラフは固定の長さで動き、**長いほど、遅く（512：約 0.15 秒／判断、1024：約 0.3 秒、2048：約 0.9 秒。Tiny-Jev 0.6B で計測）、メモリも使う**ので、アクターの選択肢が収まる、最小の段を選ぶ。
    static let lengthTiers = [512, 1024, 1536, 2048]
    /// 発言のために、選択肢のほかに取っておく長さ（日本語で、おおむね 90 字）。
    static let utteranceReserve = 160

    public let model: DecisionModel
    /// 読み込んだ入力の長さ（トークン）。
    public let length: Int

    /// 問いと選択肢（`fixed` トークン）に、発言の分を足して収まる、最小の段。最大の段でも収まらなければ `nil`。
    static func tier(forFixedLength fixed: Int) -> Int? {
        lengthTiers.first { $0 >= fixed + utteranceReserve }
    }

    private let tokenizer: BPETokenizer
    private let prompt: OptionMarkerPrompt
    private let engine: QwenDecision
    private let lock = NSLock()

    /// モデルのファイル（取得済み・検証済み）から、読み込む。数秒かかる。`candidates`（判断の候補になり得る、相手の側の全員）の選択肢と、発言が収まる長さの段を選ぶ。最大の段でも収まらなければ `inputTooLong`。
    public init(model: DecisionModel, store: ModelStore, candidates: [Actor] = []) throws {
        guard store.ensureVerified(model.weights), store.ensureVerified(model.tokenizer) else {
            throw DecisionModelError.unreadable("モデル「\(model.name)」が、取得されていない（または、検証に通らない）")
        }
        self.model = model
        tokenizer = try BPETokenizer(tokenizerJSON: store.fileURL(model.tokenizer))
        guard let marker = tokenizer.tokenId("<opt>") else { throw DecisionModelError.unreadable("トークナイザに印（<opt>）がありません") }
        let tok = tokenizer
        // 候補が 2 人以上のときだけ、選択肢を入れる（1 人なら、問わない）。
        let fixed = candidates.count < 2 ? 0 : try OptionMarkerPrompt(encode: { try tok.encode($0) }, optionTokenId: marker, maxLength: .max)
            .fixedLength(question: SpeakerPrompt.whoQuestion, options: candidates.map(SpeakerPrompt.option))
        guard let length = Self.tier(forFixedLength: fixed) else { throw DecisionModelError.inputTooLong }
        self.length = length
        prompt = OptionMarkerPrompt(encode: { try tok.encode($0) }, optionTokenId: marker, maxLength: length)
        switch model.architecture {
        case .qwenOptionMarker(let shape):
            engine = try QwenDecision(shape: shape, weights: store.fileURL(model.weights), length: length)
        }
    }

    /// 最初の 1 回は、GPU のグラフのコンパイル（数秒）が入るので、会議を始める前に、ここで済ませる。
    public func prepare() throws {
        _ = try score(state: "テスト", question: SpeakerPrompt.fillerQuestion, options: ["no", "yes"])
    }

    private func score(state: String, question: String, options: [String]) throws -> [Double] {
        lock.lock(); defer { lock.unlock() }
        let rendered = try prompt.render(state: state, question: question, options: options)
        return try engine.probabilities(ids: rendered.ids, positions: rendered.positions)
    }

    public func judge(utterance: String, candidates: [Actor]) async throws -> SpeakerJudgement {
        let who = candidates.count == 1
            ? [1.0]
            : try score(state: utterance, question: SpeakerPrompt.whoQuestion, options: candidates.map(SpeakerPrompt.option))
        let filler = try score(state: utterance, question: SpeakerPrompt.fillerQuestion, options: ["no", "yes"])[1]
        return SpeakerJudgement(probabilities: who, filler: filler)
    }
}
