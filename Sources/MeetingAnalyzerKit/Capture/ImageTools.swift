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
        let columns = 64, rows = 36, band = 2
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return false }
        func isBlank(_ column: Int, _ row: Int) -> Bool {
            let offset = (row * columns + column) * 4
            return pixels[offset + 3] < 16 || (pixels[offset] >= 245 && pixels[offset + 1] >= 245 && pixels[offset + 2] >= 245)
        }
        // 端から `band` 行（列）の、空白の割合。
        func blankShare(rows rowRange: Range<Int>, columns columnRange: Range<Int>) -> Double {
            var blank = 0, total = 0
            for row in rowRange { for column in columnRange { total += 1; if isBlank(column, row) { blank += 1 } } }
            return Double(blank) / Double(total)
        }
        let top = blankShare(rows: 0..<band, columns: 0..<columns), bottom = blankShare(rows: (rows - band)..<rows, columns: 0..<columns)
        let left = blankShare(rows: 0..<rows, columns: 0..<band), right = blankShare(rows: 0..<rows, columns: (columns - band)..<columns)
        func oneSided(_ a: Double, _ b: Double) -> Bool { (a >= 0.98 && b < 0.5) || (b >= 0.98 && a < 0.5) }
        return oneSided(top, bottom) || oneSided(left, right)
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
