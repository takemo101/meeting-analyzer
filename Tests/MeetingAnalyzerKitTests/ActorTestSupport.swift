import Foundation
import Testing
@testable import MeetingAnalyzerKit

/// ACTOR.md の試験用の例（本人 1 人・相手 2 人）。
let actorSample = """
# アクター

会議に出る人の一覧。

## 山田 太郎
- 役割: プロダクトマネージャー
- 呼ばれ方: 山田さん, PM
- 話題: 優先順位、スケジュール
- 本人: はい

## 佐藤 花子
- 役割: バックエンドのエンジニア
- 呼ばれ方: 佐藤さん
- 話題: API・データベース

## 田中 美咲
- 役割: 顧客の経理部長
- 呼ばれ方: 田中さん, 田中様
"""

func actorList(_ text: String = actorSample) throws -> ActorList {
    try ActorList.parse(text).get()
}

/// 決まった確率を返し、呼ばれ方を記録する偽の判断モデル。
final class FakeJudge: SpeakerJudge, @unchecked Sendable {
    private let lock = NSLock()
    /// 名前 → 確率（候補にいない名前は、無視。候補で、指定が無い人は 0）。候補が 1 人のときは、1。
    var probabilities: [String: Double] = [:]
    var filler = 0.0
    /// 候補の数と違う長さの答えを返す（壊れた判断モデル）。
    var malformed = false
    private(set) var calls: [[String]] = []

    func judge(utterance: String, candidates: [Actor]) async throws -> SpeakerJudgement {
        lock.withLock { calls.append(candidates.map(\.name)) }
        if malformed { return SpeakerJudgement(probabilities: [1], filler: 0) }
        let p = candidates.count == 1 ? [1.0] : candidates.map { probabilities[$0.name] ?? 0 }
        return SpeakerJudgement(probabilities: p, filler: filler)
    }
}

/// 発言に含まれる言葉で、話者を決める偽の判断モデル（言葉が無ければ、確率は、均等＝確信度が足りない）。
struct KeywordJudge: SpeakerJudge {
    let keywords: [String: [String]] = ["佐藤 花子": ["マイグレーション", "API", "データベース"], "田中 美咲": ["経理", "月末", "請求書"]]

    func judge(utterance: String, candidates: [Actor]) async throws -> SpeakerJudgement {
        let hit = candidates.map { c in keywords[c.name]?.contains { utterance.contains($0) } == true }
        guard hit.contains(true) else { return SpeakerJudgement(probabilities: Array(repeating: 1 / Double(candidates.count), count: candidates.count), filler: 0) }
        let others = Double(candidates.count - hit.filter { $0 }.count)
        let p = hit.map { $0 ? 0.97 / Double(hit.filter { $0 }.count) : 0.03 / max(1, others) }
        return SpeakerJudgement(probabilities: p, filler: 0)
    }
}

/// 決まった名前を付ける偽の部品で、会議（`LiveSession`）の流れを通す。
struct ActorRig {
    let fake = FakeInputs()
    let sink = RecordingSink()
    let clock = TestClock()
    let notices = Collected<LiveSessionNotice>()
    let store = SessionStore(root: tempURL("actors"))

    func session(labeler: SpeakerLabeler?, actors: ActorSource? = nil) -> LiveSession {
        let clock = self.clock, notices = self.notices
        return LiveSession(
            title: "テスト会議", speakers: [.you, .others], inputs: fake.inputs, sink: sink, store: store,
            options: LiveSessionOptions(actors: actors, labeler: labeler, timing: LiveSessionTiming(clock: { clock.now }, tickInterval: .seconds(60))), notify: { notices.add($0) }
        )
    }
}

enum SpeakerTestError: Error { case modelFailed }
