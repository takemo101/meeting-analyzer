import FoundationModels
import Foundation

/// Apple のオンデバイスの言語モデル（`FoundationModels`。Apple Intelligence。ダウンロード不要・外部へ送らない）で、`SpeakerJudge` の 2 つの問いに答える。
/// 答えは、ガイド付き生成で、選択肢の文字列に限る（発言の中の命令に従って、別のことを書く余地が無い）。1 問ごとに新しいセッション（前の発言を引き継がない）。
public struct AppleSpeakerJudge: SpeakerJudge {
    public enum Availability: Equatable, Sendable {
        case available
        /// 使えない理由（利用者に見せる文）。
        case unavailable(String)
    }

    public init() {}

    /// 使えるか。`locale`：会話の言語（モデルが対応している必要がある）。
    public static func availability(locale: Locale) -> Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return SystemLanguageModel.default.supportsLocale(locale) ? .available : .unavailable("この Mac の言語モデルは、日本語に対応していません")
        case .unavailable(.deviceNotEligible):
            return .unavailable("この Mac は、Apple Intelligence に対応していません")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable("Apple Intelligence が、オフです（システム設定でオンにしてください）")
        case .unavailable(.modelNotReady):
            return .unavailable("言語モデルを、準備しています（しばらくしてから、もう一度）")
        case .unavailable:
            return .unavailable("Apple の言語モデルを使えません")
        }
    }

    private static let yes = "はい"
    private static let no = "いいえ"

    public func hasCue(in utterance: String, among actors: [Actor]) async throws -> Bool {
        try await ask(SpeakerPrompt.cue(utterance: utterance, actors: actors), options: [Self.yes, Self.no]) == Self.yes
    }

    public func choose(for utterance: String, among candidates: [Actor]) async throws -> Int {
        let names = candidates.map(\.name)
        let picked = try await ask(SpeakerPrompt.choose(utterance: utterance, candidates: candidates), options: names)
        guard let index = names.firstIndex(of: picked) else { throw JudgeError.unexpectedAnswer }
        return index
    }

    enum JudgeError: Error { case unexpectedAnswer }

    private func ask(_ prompt: String, options: [String]) async throws -> String {
        let schema = try GenerationSchema(
            root: DynamicGenerationSchema(name: "Answer", properties: [
                .init(name: "answer", schema: DynamicGenerationSchema(name: "Option", anyOf: options)),
            ]),
            dependencies: []
        )
        let session = LanguageModelSession(instructions: SpeakerPrompt.instructions)
        let response = try await session.respond(to: prompt, schema: schema)
        return try response.content.value(String.self, forProperty: "answer")
    }
}
