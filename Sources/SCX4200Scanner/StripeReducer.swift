import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum StripeReducer {
    static func reduceVerticalBanding(in imageURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw StripeReductionError.cannotReadImage
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = pixels.withUnsafeMutableBytes({ buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )
        }) else {
            throw StripeReductionError.cannotReadImage
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var profile = [Double](repeating: 0, count: width)
        for x in 0..<width {
            var total = 0.0
            for y in 0..<height {
                let offset = y * bytesPerRow + x * 4
                total += 0.2126 * Double(pixels[offset])
                    + 0.7152 * Double(pixels[offset + 1])
                    + 0.0722 * Double(pixels[offset + 2])
            }
            profile[x] = total / Double(height)
        }

        let halfWindow = min(40, max(8, width / 30))
        let baseline = movingAverage(profile, halfWindow: halfWindow)
        let corrections = zip(profile, baseline).map { value, expected in
            max(-7.0, min(7.0, (value - expected) * 0.55))
        }

        for x in 0..<width {
            let correction = corrections[x]
            guard correction != 0 else { continue }
            for y in 0..<height {
                let offset = y * bytesPerRow + x * 4
                for channel in 0..<3 {
                    let value = Double(pixels[offset + channel]) - correction
                    pixels[offset + channel] = UInt8(max(0, min(255, value.rounded())))
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let correctedImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw StripeReductionError.cannotWriteImage
        }

        let temporaryURL = imageURL.deletingLastPathComponent().appendingPathComponent("corrected-scan.png")
        guard let destination = CGImageDestinationCreateWithURL(temporaryURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw StripeReductionError.cannotWriteImage
        }
        CGImageDestinationAddImage(destination, correctedImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw StripeReductionError.cannotWriteImage }
        _ = try FileManager.default.replaceItemAt(imageURL, withItemAt: temporaryURL)
    }

    private static func movingAverage(_ values: [Double], halfWindow: Int) -> [Double] {
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for index in values.indices { prefix[index + 1] = prefix[index] + values[index] }
        return values.indices.map { index in
            let lower = max(0, index - halfWindow)
            let upper = min(values.count - 1, index + halfWindow)
            return (prefix[upper + 1] - prefix[lower]) / Double(upper - lower + 1)
        }
    }
}

private enum StripeReductionError: LocalizedError {
    case cannotReadImage
    case cannotWriteImage

    var errorDescription: String? {
        switch self {
        case .cannotReadImage: "Не удалось открыть скан для коррекции полос."
        case .cannotWriteImage: "Не удалось сохранить скорректированный скан."
        }
    }
}
