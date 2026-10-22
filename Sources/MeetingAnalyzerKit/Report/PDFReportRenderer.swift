import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// 資料（PDF）の描画。CoreGraphics の PDF コンテキストへ、CoreText で本文を流し込む。A4・縦。
/// 構成：表題と概要 → **サマリー**（関連する箇所に、参考の画面を載せる）→ 付録：記録（全文。画像なし）。
/// サマリーの中の `![説明](shot-0003.jpg)`（その行だけ）が、参考の画面。時系列に画像を並べる作りにはしない。画像はメモリ上で読んで、PDF へ埋め込む。
final class PDFReportRenderer {
    private static let pageWidth: CGFloat = 595.2
    private static let pageHeight: CGFloat = 841.8
    private static let margin: CGFloat = 48
    private static let footer: CGFloat = 26
    private static let maxImageHeight: CGFloat = 230

    private let context: CGContext
    private var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
    private var pageOpen = false
    private var pageNumber = 0
    /// 現在のページの上端からの位置。
    private var cursor: CGFloat = 0

    private var contentWidth: CGFloat { Self.pageWidth - Self.margin * 2 }
    private var bottom: CGFloat { Self.pageHeight - Self.margin - Self.footer }

    private init?(data: NSMutableData, title: String) {
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "meeting-analyzer"]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else { return nil }
        self.context = context
    }

    /// PDF のデータ。作れなければ nil。
    static func render(_ data: ReportData, summary: String?, imageDirectory: URL) -> Data? {
        let output = NSMutableData()
        guard let renderer = PDFReportRenderer(data: output, title: data.title) else { return nil }
        renderer.compose(data, summary: summary, imageDirectory: imageDirectory)
        renderer.finish()
        return output as Data
    }

    // MARK: 構成

    private func compose(_ data: ReportData, summary: String?, imageDirectory: URL) {
        let summaryText = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shotTimes = Dictionary(data.shots.map { (URL(fileURLWithPath: $0.file).lastPathComponent, $0.at) }, uniquingKeysWith: { first, _ in first })
        let referenced = ReportText.imageNames(in: summaryText).filter { shotTimes[$0] != nil && FileManager.default.isReadableFile(atPath: imageDirectory.appendingPathComponent("screens").appendingPathComponent($0).path) }

        newPage()
        text(ReportText.paragraph(data.title, size: 19, boldAll: true, style: ReportText.style()), after: 6)
        var meta = "\(data.startedAt)　　長さ \(Self.clock(Double(data.durationSeconds)))　　発話 \(data.lines.count) 件"
        if !referenced.isEmpty { meta += "　　参考画面 \(referenced.count) 枚" }
        text(ReportText.paragraph(meta, size: 10, color: ReportText.muted, style: ReportText.style()), after: 5)
        text(ReportText.paragraph("音声認識の自動出力です。誤変換・欠落・聞き取れなかった箇所を含みます。専門用語・固有名詞・数値は特に不確かです。相手が複数人でも「相手」としか区別できません。", size: 8.5, color: ReportText.muted, style: ReportText.style()), after: 10)

        if summaryText.isEmpty {
            text(ReportText.paragraph("サマリーは、まだありません（エージェントが渡すと、ここに入り、関連する箇所に参考の画面が載ります）。記録の全文は、下にあります。", size: 10, color: ReportText.muted, style: ReportText.style()), after: 6)
        } else {
            text(ReportText.paragraph("サマリー", size: 15, color: ReportText.accent, boldAll: true, style: ReportText.style()), before: 8, after: 4)
            summarySection(summaryText, shotTimes: shotTimes, imageDirectory: imageDirectory)
        }

        if !summaryText.isEmpty { newPage() }
        text(ReportText.paragraph("付録：記録（全文）", size: 13, color: ReportText.accent, boldAll: true, style: ReportText.style()), before: summaryText.isEmpty ? 14 : 0, after: 6)
        let lineStyle = ReportText.style(spacingAfter: 3, head: 52, first: 0)
        let run = NSMutableAttributedString()
        for line in data.lines { run.append(Self.line(line, style: lineStyle)) }
        if data.lines.isEmpty { run.append(ReportText.paragraph("（記録はありません）", size: 10, color: ReportText.muted, style: ReportText.style())) }
        text(run)
    }

    /// サマリーを流し込む。`![説明](ファイル名)` だけの行は、その位置に、参考の画面として入れる。
    private func summarySection(_ summary: String, shotTimes: [String: Double], imageDirectory: URL) {
        var buffer: [String] = []
        func flush() {
            if !buffer.isEmpty { text(ReportText.summary(buffer.joined(separator: "\n"))); buffer = [] }
        }
        for line in summary.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            guard let reference = ReportText.imageReference(line) else { buffer.append(line); continue }
            flush()
            guard let time = shotTimes[reference.name] else {
                text(ReportText.paragraph("（参考画面が見つかりません：\(reference.name)）", size: 8.5, color: ReportText.muted, style: ReportText.style()), before: 4, after: 4)
                continue
            }
            let caption = "参考画面（\(Self.clock(time))）" + (reference.alt.isEmpty ? "" : "　" + reference.alt)
            image(imageDirectory.appendingPathComponent("screens").appendingPathComponent(reference.name), caption: caption)
        }
        flush()
    }

    /// `[mm:ss] 本人: 本文`。時刻と話者は薄く、本人は色を変える。
    private static func line(_ line: ReportData.Line, style: CTParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let stamp = "[\(clock(line.at))]  "
        result.append(NSAttributedString(string: stamp, attributes: ReportText.attributes(font: ReportText.font(ReportText.regular, 8.5), color: ReportText.muted, style: style)))
        let speakerColor = line.speaker == Speaker.you.displayName ? ReportText.accent : ReportText.ink
        result.append(NSAttributedString(string: line.speaker + "：", attributes: ReportText.attributes(font: ReportText.font(ReportText.bold, 9.5), color: speakerColor, style: style)))
        result.append(NSAttributedString(string: line.text + "\n", attributes: ReportText.attributes(font: ReportText.font(ReportText.regular, 9.5), color: ReportText.ink, style: style)))
        return result
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: ページ

    private func newPage() {
        endPage()
        context.beginPDFPage(nil)
        pageOpen = true
        pageNumber += 1
        cursor = Self.margin
    }

    private func endPage() {
        guard pageOpen else { return }
        let label = NSAttributedString(string: "\(pageNumber)", attributes: ReportText.attributes(font: ReportText.font(ReportText.regular, 8), color: ReportText.muted, style: ReportText.style()))
        let line = CTLineCreateWithAttributedString(label)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (Self.pageWidth - width) / 2, y: Self.margin - 6)
        CTLineDraw(line, context)
        context.endPDFPage()
        pageOpen = false
    }

    private func finish() {
        endPage()
        context.closePDF()
    }

    /// 属性つきの本文を、現在の位置から流し込む。ページに収まらなければ、次のページへ続ける。
    /// `before`・`after`：ブロックの前後の空き（ページの先頭では、前の空きは取らない）。
    private func text(_ string: NSAttributedString, before: CGFloat = 0, after: CGFloat = 0) {
        guard string.length > 0 else { return }
        if cursor > Self.margin + 0.5 { cursor += before }
        let setter = CTFramesetterCreateWithAttributedString(string)
        var location = 0
        while location < string.length {
            let available = bottom - cursor
            if available < 24 { newPage(); continue }
            let rect = CGRect(x: Self.margin, y: Self.pageHeight - cursor - available, width: contentWidth, height: available)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: location, length: 0), CGPath(rect: rect, transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 {
                // 1 行も入らない。新しいページでも入らないなら、先へ進む（無限に繰り返さない）。
                if cursor <= Self.margin + 0.5 { location += 1 } else { newPage() }
                continue
            }
            CTFrameDraw(frame, context)
            let used = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: location, length: visible.length), nil, CGSize(width: contentWidth, height: .greatestFiniteMagnitude), nil).height
            cursor += ceil(used)
            location += visible.length
            if location < string.length { newPage() }
        }
        cursor += after
    }

    /// 参考の画面を、キャプション（画像の下）つきで置く。読めない画像は、その旨を 1 行で示す。サマリーの流れを邪魔しない大きさ（幅の 75%・高さ 230pt まで）。
    private func image(_ url: URL, caption: String) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            text(ReportText.paragraph("（参考画面を読めませんでした：\(url.lastPathComponent)）", size: 8.5, color: ReportText.muted, style: ReportText.style()), before: 4, after: 4)
            return
        }
        let width = CGFloat(picture.width), height = CGFloat(picture.height)
        let scale = min(contentWidth * 0.75 / width, Self.maxImageHeight / height, 1)
        let size = CGSize(width: width * scale, height: height * scale)
        let captionHeight: CGFloat = 24
        if cursor > Self.margin + 0.5 { cursor += 4 }
        if cursor + size.height + captionHeight > bottom { newPage() }
        context.draw(picture, in: CGRect(x: Self.margin + 8, y: Self.pageHeight - cursor - size.height, width: size.width, height: size.height))
        cursor += size.height + 3
        text(ReportText.paragraph(caption, size: 8.5, color: ReportText.muted, style: ReportText.style(head: 8, first: 8)), after: 8)
    }
}
