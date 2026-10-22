import Foundation

/// 会議後の資料（PDF）の元データ（SPEC §3.11）。セッションの終了で、`sessions/<id>/report-data.json` に書く。
/// エージェントが、あとからサマリーを渡したときに、同じデータから、PDF を作り直せる。
public struct ReportData: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable {
        /// セッションの開始からの秒数。
        public var at: Double
        public var speaker: String
        public var text: String

        public init(at: Double, speaker: String, text: String) {
            self.at = at
            self.speaker = speaker
            self.text = text
        }
    }

    public struct Shot: Codable, Sendable, Equatable {
        /// 撮った時刻（セッションの開始からの秒数）。
        public var at: Double
        /// セッションのディレクトリからの相対パス（例：`screens/shot-0001.jpg`）。
        public var file: String

        public init(at: Double, file: String) {
            self.at = at
            self.file = file
        }
    }

    public var title: String
    /// 表示用の開始日時。
    public var startedAt: String
    public var durationSeconds: Int
    public var lines: [Line]
    public var shots: [Shot]

    public init(title: String, startedAt: String, durationSeconds: Int, lines: [Line], shots: [Shot]) {
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.lines = lines
        self.shots = shots
    }
}

public enum ReportError: Error, Equatable, Sendable {
    /// 元データが無い（資料を作らなかった会議）・読めない。
    case noData
    case renderFailed
    case writeFailed
}

/// 資料（PDF）を、セッションのディレクトリへ書く。ディレクトリ 0700・ファイル 0600。
public enum ReportBuilder {
    public static let dataName = "report-data.json"
    public static let pdfName = "report.pdf"

    /// 元データを保存して、PDF を作る。`summary` があれば、先頭に入れる。
    public static func write(_ data: ReportData, summary: String?, in sessionDirectory: URL) -> Result<URL, ReportError> {
        do {
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let json = try JSONEncoder().encode(data)
            try save(json, to: sessionDirectory.appendingPathComponent(dataName))
        } catch {
            return .failure(.writeFailed)
        }
        return render(data, summary: summary, in: sessionDirectory)
    }

    /// 保存した元データから、サマリーを入れて、PDF を作り直す。
    /// `keepScreens`：資料に入れる画面の画像（ファイル名。例：`shot-0003.jpg`）。`nil` なら、すべて残す。指定したときは、**入れなかった画像を、ディスクから消し**、元データからも外す
    /// （エージェントが、会話に関係ないと判断した画像を、資料にも、ディスクにも残さない）。空の配列なら、画像なしの資料になる。
    public static func rebuild(summary: String?, keepScreens: Set<String>? = nil, in sessionDirectory: URL) -> Result<URL, ReportError> {
        guard let json = try? Data(contentsOf: sessionDirectory.appendingPathComponent(dataName)),
              var data = try? JSONDecoder().decode(ReportData.self, from: json) else { return .failure(.noData) }
        if let keepScreens {
            let dropped = data.shots.filter { !keepScreens.contains(URL(fileURLWithPath: $0.file).lastPathComponent) }
            for shot in dropped { try? FileManager.default.removeItem(at: sessionDirectory.appendingPathComponent(shot.file)) }
            data.shots.removeAll { dropped.contains($0) }
            guard let updated = try? JSONEncoder().encode(data), (try? save(updated, to: sessionDirectory.appendingPathComponent(dataName))) != nil else { return .failure(.writeFailed) }
        }
        return render(data, summary: summary, in: sessionDirectory)
    }

    private static func render(_ data: ReportData, summary: String?, in sessionDirectory: URL) -> Result<URL, ReportError> {
        guard let pdf = PDFReportRenderer.render(data, summary: summary, imageDirectory: sessionDirectory) else { return .failure(.renderFailed) }
        let file = sessionDirectory.appendingPathComponent(pdfName)
        do {
            try save(pdf, to: file)
            return .success(file)
        } catch {
            return .failure(.writeFailed)
        }
    }

    private static func save(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
