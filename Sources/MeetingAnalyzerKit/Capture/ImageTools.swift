import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 画面の画像の加工（署名の計算・縮小・JPEG）。画像はメモリ上だけで扱い、JPEG にするのは、エージェントへ渡す分だけ。
public enum ImageTools {
    /// 画像の署名（48×27 の明るさ）。
    public static func signature(of image: CGImage) -> ScreenSignature? {
        let columns = ScreenSignature.columns, rows = ScreenSignature.rows
        var pixels = [UInt8](repeating: 0, count: columns * rows)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        return drawn ? ScreenSignature(cells: pixels) : nil
    }

    /// 描きかけの画像か：上下・左右の、どちらか一方の端だけが、一様に空白（透明、または白）で、反対側の端は、空白でない。
    /// ウィンドウが大きくなる最中（フルスクリーンへの切り替えなど）に撮ると、増えた部分が、白（透明）のまま、片側（上と右）に残るため。
    /// 四方が白い余白の書類・スライドは、反対側も空白なので、当てはまらない。
    public static func hasUnrenderedBand(_ image: CGImage) -> Bool {
        let columns = 64, rows = 36
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return false }
        func isBlank(_ column: Int, _ row: Int) -> Bool {
            let offset = (row * columns + column) * 4
            return pixels[offset + 3] < 16 || (pixels[offset] >= 245 && pixels[offset + 1] >= 245 && pixels[offset + 2] >= 245)
        }
        // いちばん端の `band` 行（列）の、空白の割合（格子の 1 マスは、画像の 1/36〜1/64。それより太い帯を見つける）。
        func blankShare(rows rowRange: Range<Int>, columns columnRange: Range<Int>) -> Double {
            var blank = 0, total = 0
            for row in rowRange { for column in columnRange { total += 1; if isBlank(column, row) { blank += 1 } } }
            return Double(blank) / Double(total)
        }
        // 端の 2 行（列）のうち、空白が多いほう（いちばん端が、画面の縁の細い線で、空白でなくても、その内側が空白なら、帯とみなす）。
        func edge(_ first: Double, _ second: Double) -> Double { max(first, second) }
        let top = edge(blankShare(rows: 0..<1, columns: 0..<columns), blankShare(rows: 1..<2, columns: 0..<columns))
        let bottom = edge(blankShare(rows: (rows - 1)..<rows, columns: 0..<columns), blankShare(rows: (rows - 2)..<(rows - 1), columns: 0..<columns))
        let left = edge(blankShare(rows: 0..<rows, columns: 0..<1), blankShare(rows: 0..<rows, columns: 1..<2))
        let right = edge(blankShare(rows: 0..<rows, columns: (columns - 1)..<columns), blankShare(rows: 0..<rows, columns: (columns - 2)..<(columns - 1)))
        func oneSided(_ a: Double, _ b: Double) -> Bool { (a >= 0.98 && b < 0.5) || (b >= 0.98 && a < 0.5) }
        return oneSided(top, bottom) || oneSided(left, right)
    }

    /// 描きかけ・窓の枠の余りの、**片側だけの空白の帯**を、切り落とす。四方が白い余白の画像は、そのまま（帯が、片側だけのとき）。
    /// フルスクリーンの動画では、ウィンドウの枠が、見えている内容より大きく、上と右に、空白（白・透明）が残る画像になることがある。
    /// 空白は、端から内側へ、ほぼ全面が空白の行・列が続くあいだだけ。辺の 15% を超える空白は、内容（白い書類の上部など）とみなして、切り落とさない。切り落とした結果が、元の半分に満たなければ、元の画像のまま（誤判定で、内容を失わない）。
    public static func trimmingUnrenderedBands(_ image: CGImage) -> CGImage {
        guard hasUnrenderedBand(image) else { return image }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }
        func blank(_ x: Int, _ y: Int) -> Bool {
            let offset = (y * width + x) * 4
            return pixels[offset + 3] < 16 || (pixels[offset] >= 245 && pixels[offset + 1] >= 245 && pixels[offset + 2] >= 245)
        }
        // バッファの行 0 は、画像の上端（`CGContext` に描いた画像は、上から下の順に並ぶ）。
        func rowBlank(_ y: Int) -> Bool { (0..<width).filter { blank($0, y) }.count * 1000 >= width * 995 }
        func columnBlank(_ x: Int) -> Bool { (0..<height).filter { blank(x, $0) }.count * 1000 >= height * 995 }
        // 端から、空白の行（列）が続く本数。いちばん端の、細い線（3 本まで。画面の縁の線など）は、空白の前に、数えずに飛ばして、帯に含める。
        func run(_ count: Int, _ isBlank: (Int) -> Bool, fromEnd: Bool) -> Int {
            func line(_ n: Int) -> Int { fromEnd ? count - 1 - n : n }
            var edge = 0
            while edge < 3, edge < count, !isBlank(line(edge)) { edge += 1 }
            var n = edge
            while n < count, isBlank(line(n)) { n += 1 }
            return n - edge >= 8 ? n : 0
        }
        let topRun = run(height, rowBlank, fromEnd: false), bottomRun = run(height, rowBlank, fromEnd: true)
        let leftRun = run(width, columnBlank, fromEnd: false), rightRun = run(width, columnBlank, fromEnd: true)
        // 反対側が空白でない側だけ、切り落とす（四方が空白の余白は、触らない）。
        // 太すぎる空白（辺の 15% を超える）は、帯でなく、内容（白い書類の上部など）とみなして、切り落とさない。
        func capped(_ run: Int, of length: Int) -> Int { run * 100 <= length * 15 ? run : 0 }
        let top = bottomRun == 0 ? capped(topRun, of: height) : 0, bottom = topRun == 0 ? capped(bottomRun, of: height) : 0
        let left = rightRun == 0 ? capped(leftRun, of: width) : 0, right = leftRun == 0 ? capped(rightRun, of: width) : 0
        let rect = CGRect(x: left, y: top, width: width - left - right, height: height - top - bottom)
        guard rect.width >= CGFloat(width) / 2, rect.height >= CGFloat(height) / 2, rect.size != CGSize(width: width, height: height), let cropped = image.cropping(to: rect) else { return image }
        return cropped
    }

    /// 長いほうの辺を `maxEdge` 以下に縮めた JPEG。縮める必要がなければ、そのまま。
    public static func jpegData(of image: CGImage, maxEdge: Int = 1280, quality: Double = 0.6) -> Data? {
        let longest = max(image.width, image.height)
        var source = image
        if longest > maxEdge {
            let scale = Double(maxEdge) / Double(longest)
            let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            source = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, source, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
