import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// 資料（PDF）の描画。CoreGraphics の PDF コンテキストへ、CoreText で本文を流し込み、画面の画像を時刻の位置に挟む。A4・縦。
/// 構成：表題と概要 → サマリー（あれば）→ 記録と画面（時系列）。画像はメモリ上で読んで、PDF へ埋め込む。
final class PDFReportRenderer {
    private static let pageWidth: CGFloat = 595.2
    private static let pageHeight: CGFloat = 841.8
    private static let margin: CGFloat = 48
    private static let footer: CGFloat = 26
    private static let maxImageHeight: CGFloat = 300

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
        newPage()
        text(ReportText.paragraph(data.title, size: 19, boldAll: true, style: ReportText.style()), after: 6)
        let meta = "\(data.startedAt)　　長さ \(Self.clock(Double(data.durationSeconds)))　　発話 \(data.lines.count) 件　　画面 \(data.shots.count) 枚"
        text(ReportText.paragraph(meta, size: 10, color: ReportText.muted, style: ReportText.style()), after: 5)
        text(ReportText.paragraph("音声認識の自動出力です。誤変換・欠落・聞き取れなかった箇所を含みます。専門用語・固有名詞・数値は特に不確かです。相手が複数人でも「相手」としか区別できません。", size: 8.5, color: ReportText.muted, style: ReportText.style()), after: 10)

        if let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text(ReportText.paragraph("サマリー", size: 15, color: ReportText.accent, boldAll: true, style: ReportText.style()), before: 8, after: 4)
            text(ReportText.summary(summary))
        }

        text(ReportText.paragraph("記録と画面", size: 15, color: ReportText.accent, boldAll: true, style: ReportText.style()), before: 18, after: 6)
        let lineStyle = ReportText.style(spacingAfter: 3, head: 52, first: 0)
        var shots = data.shots.sorted { $0.at < $1.at }[...]
        var run = NSMutableAttributedString()
        func flushRun() {
            if run.length > 0 { text(run); run = NSMutableAttributedString() }
        }
        func placeShots(before time: Double?) {
            while let shot = shots.first, time == nil || shot.at <= time! {
                shots = shots.dropFirst()
                flushRun()
                image(imageDirectory.appendingPathComponent(shot.file), at: shot.at)
            }
        }
        for line in data.lines {
            placeShots(before: line.at)
            run.append(Self.line(line, style: lineStyle))
        }
        placeShots(before: nil)
        flushRun()
        if data.lines.isEmpty && data.shots.isEmpty {
            text(ReportText.paragraph("（記録はありません）", size: 10, color: ReportText.muted, style: ReportText.style()))
        }
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

    /// 画面の画像を、キャプションつきで置く。読めない画像は、その旨を 1 行で示す。
    private func image(_ url: URL, at time: Double) {
        let caption = ReportText.paragraph("画面（\(Self.clock(time))）", size: 8.5, color: ReportText.muted, style: ReportText.style())
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            text(ReportText.paragraph("画面（\(Self.clock(time))）：画像を読めませんでした", size: 8.5, color: ReportText.muted, style: ReportText.style()), before: 8, after: 3)
            return
        }
        let width = CGFloat(picture.width), height = CGFloat(picture.height)
        let scale = min(contentWidth / width, Self.maxImageHeight / height, 1)
        let size = CGSize(width: width * scale, height: height * scale)
        let captionHeight: CGFloat = 20
        if cursor + captionHeight + size.height > bottom { newPage() }
        text(caption, before: 8, after: 3)
        if cursor + size.height > bottom { newPage() }
        context.draw(picture, in: CGRect(x: Self.margin, y: Self.pageHeight - cursor - size.height, width: size.width, height: size.height))
        cursor += size.height + 6
    }
}
