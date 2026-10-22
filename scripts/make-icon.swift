import AppKit

// meeting-analyzer のアイコンを、コードで生成する（外部の素材は使わない）。
// 使い方（リポジトリのルートで）: ./scripts/make-icon.sh   （中で swift scripts/make-icon.swift <出力先> を実行する）
// 出力：<出力先>/AppIcon.iconset/ … iconutil で AppIcon.icns にするための、各サイズの PNG
// 図柄：紫がかった青の角丸の四角に、白い吹き出し（会話）と、その中の波形（音声）。「音声を文字にして、会話を渡す」を表す。

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output directory>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

/// `size` × `size` ピクセルの PNG を作る。`draw` は、`extent` × `extent` の座標系（左下原点）で描く。
func png(size: Int, extent: CGFloat, draw: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / extent, y: CGFloat(size) / extent)
    draw(ctx)
    return rep.representation(using: .png, properties: [:])!
}

func gradient(_ top: CGColor, _ bottom: CGColor) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: [top, bottom] as CFArray, locations: [0, 1])!
}

// MARK: - アプリのアイコン（1024 の座標系）

func drawAppIcon(_ ctx: CGContext) {
    // macOS のアイコンの形：1024 の中に、余白 100 を残した 824 の角丸の四角。
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 188, cornerHeight: 188, transform: nil)

    // 影つきで、下地を塗る。
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.38))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x4A3FD0))
    ctx.fillPath()
    ctx.restoreGState()

    // 青（上）から紫がかった濃い青（下）へ。
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient(color(0x6F86FF), color(0x3A2BB8)), start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    // 上端に、細い光。
    ctx.setFillColor(color(0xFFFFFF, 0.22))
    ctx.fill(CGRect(x: 100, y: 884, width: 824, height: 40))
    ctx.restoreGState()

    // 白い吹き出し（角丸の四角と、左下のしっぽ）。
    let bubble = CGRect(x: 214, y: 360, width: 596, height: 384)
    let bubblePath = CGMutablePath()
    bubblePath.addRoundedRect(in: bubble, cornerWidth: 128, cornerHeight: 128)
    bubblePath.move(to: CGPoint(x: 316, y: 372))
    bubblePath.addLine(to: CGPoint(x: 282, y: 262))
    bubblePath.addQuadCurve(to: CGPoint(x: 296, y: 248), control: CGPoint(x: 280, y: 250))
    bubblePath.addLine(to: CGPoint(x: 470, y: 372))
    bubblePath.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x10104A, 0.42))
    ctx.addPath(bubblePath)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // 吹き出しの中の波形（5 本の丸い棒。中央がいちばん長い）。
    let heights: [CGFloat] = [112, 196, 268, 196, 112]
    let barWidth: CGFloat = 56, gap: CGFloat = 38
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let originX = bubble.midX - total / 2
    for (index, height) in heights.enumerated() {
        let rect = CGRect(x: originX + CGFloat(index) * (barWidth + gap), y: bubble.midY - height / 2, width: barWidth, height: height)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(gradient(color(0x5B6CFF), color(0x4A2FD0)), start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        ctx.restoreGState()
    }
}

// iconutil が要る各サイズ（1x と 2x）。
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for item in sizes {
    try png(size: item.pixels, extent: 1024, draw: drawAppIcon).write(to: iconset.appendingPathComponent(item.name + ".png"))
}
