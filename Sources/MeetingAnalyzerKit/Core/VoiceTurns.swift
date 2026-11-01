import Foundation

/// 声の分離が出した、1 人の話者の 1 区間（秒）。`speaker` は、分離器が付けた名前（会議ごとの、意味のない文字列）。
public struct VoiceSegment: Sendable, Equatable {
    public let speaker: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// 発話に、話者 ID（1, 2, …）を付ける規則（SPEC §3.14）。純粋な規則。
public enum VoiceAssignment {
    /// 発話の区間（時刻順）ごとに、**最も長く重なる**話者へ付ける。重なりが無い発話は `nil`。
    /// ID は、**発話の出現の順に 1 から**（同じ話者は、同じ ID）。重なりが同じ長さなら、区間の開始が早い話者（それも同じなら名前の順）。
    public static func assign(spans: [(start: TimeInterval, end: TimeInterval)], segments: [VoiceSegment]) -> (ids: [Int?], count: Int, speakers: [String]) {
        var order: [String: Int] = [:]
        var ids: [Int?] = []
        for span in spans {
            var overlap: [String: (total: TimeInterval, first: TimeInterval)] = [:]
            for segment in segments {
                let shared = min(span.end, segment.end) - max(span.start, segment.start)
                guard shared > 0 else { continue }
                let known = overlap[segment.speaker]
                overlap[segment.speaker] = ((known?.total ?? 0) + shared, min(known?.first ?? .infinity, segment.start))
            }
            let best = overlap.min { lhs, rhs in
                if lhs.value.total != rhs.value.total { return lhs.value.total > rhs.value.total }
                if lhs.value.first != rhs.value.first { return lhs.value.first < rhs.value.first }
                return lhs.key < rhs.key
            }
            guard let speaker = best?.key else { ids.append(nil); continue }
            if order[speaker] == nil { order[speaker] = order.count + 1 }
            ids.append(order[speaker])
        }
        return (ids, order.count, order.sorted { $0.value < $1.value }.map(\.key))
    }
}

/// 取り込んだ音声（一時停止ごとに区切れた、いくつかの塊）と、会議の時刻（開始からの秒）の対応。
/// 一時停止のあいだの音は取り込まないので、音声を**つなげた時刻**と、会議の時刻は、塊ごとにずれる。
public struct AudioTimeline: Sendable, Equatable {
    public struct Piece: Sendable, Equatable {
        /// この塊の最初の音の、会議の時刻（秒）。
        public let origin: TimeInterval
        /// この塊の長さ（秒）。
        public let duration: TimeInterval

        public init(origin: TimeInterval, duration: TimeInterval) {
            self.origin = origin
            self.duration = duration
        }
    }

    public let pieces: [Piece]

    public init(pieces: [Piece]) { self.pieces = pieces }

    /// つなげた音声の中の区間 → 会議の時刻の区間（塊の境をまたぐ区間は、塊ごとに分ける）。
    public func sessionSegments(from segments: [VoiceSegment]) -> [VoiceSegment] {
        var result: [VoiceSegment] = []
        for segment in segments {
            var offset: TimeInterval = 0
            for piece in pieces {
                let lower = max(segment.start, offset), upper = min(segment.end, offset + piece.duration)
                if upper > lower {
                    result.append(VoiceSegment(speaker: segment.speaker, start: piece.origin + (lower - offset), end: piece.origin + (upper - offset)))
                }
                offset += piece.duration
            }
        }
        return result
    }

    /// 会議の時刻の区間 → つなげた音声の中の、再生する区間（聞き直しのため）。区間と重なる**最初の塊**の中だけ（塊の境はまたがない）。重なる塊が無ければ `nil`。
    /// `position`：つなげた音声の中の開始（秒）。`duration`：長さ（秒。`limit` まで）。
    public func playback(start: TimeInterval, end: TimeInterval, limit: TimeInterval = 20) -> (position: TimeInterval, duration: TimeInterval)? {
        var offset: TimeInterval = 0
        for piece in pieces {
            let lower = max(start, piece.origin), upper = min(end, piece.origin + piece.duration)
            if upper > lower { return (offset + (lower - piece.origin), min(upper - lower, limit)) }
            offset += piece.duration
        }
        return nil
    }
}
