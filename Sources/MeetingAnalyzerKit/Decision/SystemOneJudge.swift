import Foundation

/// ダウンロードした System One 型の判断モデルで、`SpeakerJudge` の問いに答える（SPEC §3.13）。確率（確信度）を返す。
/// 会議の間だけ、モデルを読み込む（GPU のメモリに、重みの約 1.2 GB。会議が終わって、これを手放すと、解放される）。
/// 入力が違うモデルでも、同じ呼び方になるよう、系統ごとの実装（いまは `QwenDecision`）を、ここで選ぶ。
public final class SystemOneJudge: SpeakerJudge, @unchecked Sendable {
    /// 入力の長さの上限（トークン）。アクターの選択肢（1 人 40 トークン前後）と、発言（日本語で、おおむね 150 字）が収まる。
    static let maxLength = 512

    public let model: DecisionModel
    private let tokenizer: BPETokenizer
    private let prompt: OptionMarkerPrompt
    private let engine: QwenDecision
    private let lock = NSLock()

    /// モデルのファイル（取得済み・検証済み）から、読み込む。数秒かかる。
    public init(model: DecisionModel, store: ModelStore) throws {
        guard store.ensureVerified(model.weights), store.ensureVerified(model.tokenizer) else {
            throw DecisionModelError.unreadable("モデル「\(model.name)」が、取得されていない（または、検証に通らない）")
        }
        self.model = model
        tokenizer = try BPETokenizer(tokenizerJSON: store.fileURL(model.tokenizer))
        guard let marker = tokenizer.tokenId("<opt>") else { throw DecisionModelError.unreadable("トークナイザに印（<opt>）がありません") }
        let tok = tokenizer
        prompt = OptionMarkerPrompt(encode: { try tok.encode($0) }, optionTokenId: marker, maxLength: Self.maxLength)
        switch model.architecture {
        case .qwenOptionMarker(let shape):
            engine = try QwenDecision(shape: shape, weights: store.fileURL(model.weights), length: Self.maxLength)
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
