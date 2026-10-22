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
