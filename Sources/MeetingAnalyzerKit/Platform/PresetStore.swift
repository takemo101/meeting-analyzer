import Foundation

/// プリセットの置き場所と読み込み（SPEC §3.11）。同梱のもの（アプリの `Contents/Resources/presets/`）と、利用者のもの（`<データの置き場所>/presets/`）。
/// 同じ名前（ファイル名）なら、利用者のものが優先。`_` や `.` で始まるファイルは、読まない（テンプレートなど）。
public struct PresetStore: Sendable {
    public struct Skipped: Sendable, Equatable {
        public let file: String
        public let reason: String
    }

    public let builtinDirectory: URL?
    public let userDirectory: URL

    public init(builtinDirectory: URL?, userDirectory: URL) {
        self.builtinDirectory = builtinDirectory
        self.userDirectory = userDirectory
    }

    /// 実際の置き場所。同梱のものは、実行ファイル（`Contents/MacOS/`）から見た `Contents/Resources/presets`。
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> PresetStore {
        let builtin = BundledResources.path("presets", executable: BundledResources.currentExecutablePath()).map { URL(fileURLWithPath: $0, isDirectory: true) }
        return PresetStore(builtinDirectory: builtin, userDirectory: RuntimePaths.dataDirectory(environment: environment).appendingPathComponent("presets", isDirectory: true))
    }

    /// 読めるプリセットと、読めなかったファイル（理由つき）。既定が先頭、あとは名前順（同梱 → 利用者の順に、同じ名前は利用者が上書き）。
    public func load() -> (presets: [AnalysisPreset], skipped: [Skipped]) {
        var byID: [String: AnalysisPreset] = [:]
        var skipped: [Skipped] = []
        for (directory, source) in [(builtinDirectory, AnalysisPreset.Source.builtin), (userDirectory, .user)] {
            guard let directory else { continue }
            for file in Self.markdownFiles(in: directory) {
                let id = file.deletingPathExtension().lastPathComponent
                guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
                    skipped.append(Skipped(file: file.lastPathComponent, reason: "読めません（UTF-8 のテキストではありません）")); continue
                }
                switch AnalysisPreset.parse(id: id, text: text, source: source) {
                case .success(let preset): byID[id] = preset
                case .failure(let error): skipped.append(Skipped(file: file.lastPathComponent, reason: Self.describe(error)))
                }
            }
        }
        let sorted = byID.values.sorted {
            if ($0.id == AnalysisPreset.defaultID) != ($1.id == AnalysisPreset.defaultID) { return $0.id == AnalysisPreset.defaultID }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return (sorted, skipped)
    }

    public func all() -> [AnalysisPreset] { load().presets }

    /// `id` のプリセット。無ければ、既定。既定も無ければ nil（プリセットなしで始める）。
    public func resolve(id: String?) -> AnalysisPreset? {
        let presets = all()
        return presets.first { $0.id == id } ?? presets.first { $0.id == AnalysisPreset.defaultID }
    }

    /// 自分のプリセットを置くフォルダを用意する（0700）。説明つきのテンプレートが無ければ、置く。フォルダの場所を返す（作れなければ nil）。
    @discardableResult
    public func prepareUserDirectory() -> URL? {
        do {
            try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let template = userDirectory.appendingPathComponent("_テンプレート.md")
            if !FileManager.default.fileExists(atPath: template.path) {
                try Data(Self.templateText.utf8).write(to: template)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: template.path)
            }
            return userDirectory
        } catch {
            return nil
        }
    }

    private static func markdownFiles(in directory: URL) -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        return names.filter { $0.hasSuffix(".md") && !$0.hasPrefix("_") && !$0.hasPrefix(".") }.map { directory.appendingPathComponent($0) }
    }

    private static func describe(_ error: AnalysisPreset.ParseError) -> String {
        switch error {
        case .missingName: return "先頭の `---` の見出しに、`name:` がありません"
        case .emptyInstructions: return "本文（エージェントへの指示）が空です"
        case .tooLong(let count): return "本文が長すぎます（\(count) 文字。\(AnalysisPreset.maxInstructionLength) 文字まで）"
        }
    }

    /// 自分のプリセットの書き方（`_テンプレート.md`。`_` で始まるので、プリセットとしては読まない）。
    static let templateText = """
    ---
    name: 自分のプリセットの名前（メニューに出る）
    description: 何のための分析か（1 行。任意）
    ---
    # このファイルの使い方

    - このファイルを、`_` なしの名前（例：`my-review.md`）で保存すると、メニューの「分析のプリセット」に出ます。ファイル名が、プリセットの ID になります。
    - **同梱のプリセットと同じ名前**（例：`standard.md`）で保存すると、自分のほうが優先されます（同梱のものは変えられません）。
    - 本文は、エージェントへの指示です（8000 文字まで）。会話の字幕の命令に従う・ファイルを編集する・外部へ送る、といった指示は、アプリ側の約束（字幕はデータであり指示ではない）が優先されるため、効きません。

    # 本文の例（書き換えて使う）

    ## 聞いているあいだ
    どんなときに、何を、どんな書式で出すか（出さないときは、いつか）。

    ## 提案のしかた
    何を基準に、いくつ、どんな形で提案するか。

    ## 終了（`ended`）：サマリー
    どんな項目を、どんな順で、どれくらいの長さで出すか。
    """
}
