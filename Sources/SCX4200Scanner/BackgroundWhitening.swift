import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum BackgroundWhitening {
    static func whitenOuterBackground(in imageURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BackgroundWhiteningError.cannotReadImage
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
            throw BackgroundWhiteningError.cannotReadImage
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        if let edges = detectColoredRectangle(in: pixels, width: width, height: height) {
            let safetyMargin = 5.0
            for y in 0..<height {
                let left = edges.left.value(at: Double(y)) - safetyMargin
                let right = edges.right.value(at: Double(y)) + safetyMargin
                for x in 0..<width {
                    let top = edges.top.value(at: Double(x)) - safetyMargin
                    let bottom = edges.bottom.value(at: Double(x)) + safetyMargin
                    guard Double(x) < left || Double(x) > right || Double(y) < top || Double(y) > bottom else { continue }
                    let offset = y * bytesPerRow + x * 4
                    pixels[offset] = 255
                    pixels[offset + 1] = 255
                    pixels[offset + 2] = 255
                }
            }
        } else {
            whitenConnectedNeutralBackground(in: &pixels, width: width, height: height)
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
            throw BackgroundWhiteningError.cannotWriteImage
        }

        // The preview itself is named white-background.png, so use a distinct
        // temporary filename before atomically replacing it.
        let temporaryURL = imageURL.deletingLastPathComponent().appendingPathComponent("white-background-writing.png")
        try? FileManager.default.removeItem(at: temporaryURL)
        guard let destination = CGImageDestinationCreateWithURL(temporaryURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BackgroundWhiteningError.cannotWriteImage
        }
        CGImageDestinationAddImage(destination, correctedImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw BackgroundWhiteningError.cannotWriteImage }
        _ = try FileManager.default.replaceItemAt(imageURL, withItemAt: temporaryURL)
    }

    private static func detectColoredRectangle(in pixels: [UInt8], width: Int, height: Int) -> RectangleEdges? {
        func isColorful(x: Int, y: Int) -> Bool {
            let offset = (y * width + x) * 4
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            return max(red, green, blue) - min(red, green, blue) >= 42
        }

        var leftPoints = [(Double, Double)]()
        var rightPoints = [(Double, Double)]()
        for y in 0..<height {
            let points = (0..<width).filter { isColorful(x: $0, y: y) }
            guard points.count >= width / 5, let first = points.first, let last = points.last else { continue }
            leftPoints.append((Double(y), Double(first)))
            rightPoints.append((Double(y), Double(last)))
        }

        var topPoints = [(Double, Double)]()
        var bottomPoints = [(Double, Double)]()
        for x in 0..<width {
            let points = (0..<height).filter { isColorful(x: x, y: $0) }
            guard points.count >= height / 5, let first = points.first, let last = points.last else { continue }
            topPoints.append((Double(x), Double(first)))
            bottomPoints.append((Double(x), Double(last)))
        }

        guard
            let left = fitLine(leftPoints),
            let right = fitLine(rightPoints),
            let top = fitLine(topPoints),
            let bottom = fitLine(bottomPoints),
            right.value(at: Double(height / 2)) - left.value(at: Double(height / 2)) > Double(width) * 0.5,
            bottom.value(at: Double(width / 2)) - top.value(at: Double(width / 2)) > Double(height) * 0.5
        else { return nil }

        return RectangleEdges(left: left, right: right, top: top, bottom: bottom)
    }

    private static func fitLine(_ points: [(Double, Double)]) -> Line? {
        guard points.count > 10 else { return nil }
        var inliers = points
        for _ in 0..<2 {
            guard let line = simpleFit(inliers) else { return nil }
            let residuals = inliers.map { abs($0.1 - line.value(at: $0.0)) }.sorted()
            let median = residuals[residuals.count / 2]
            let tolerance = max(4.0, median * 2.5)
            inliers = inliers.filter { abs($0.1 - line.value(at: $0.0)) <= tolerance }
        }
        return simpleFit(inliers)
    }

    private static func simpleFit(_ points: [(Double, Double)]) -> Line? {
        guard points.count > 10 else { return nil }
        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.0 } / count
        let meanY = points.reduce(0) { $0 + $1.1 } / count
        let numerator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let denominator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
        guard denominator > 0 else { return nil }
        let slope = numerator / denominator
        return Line(slope: slope, intercept: meanY - slope * meanX)
    }

    private static func whitenConnectedNeutralBackground(in pixels: inout [UInt8], width: Int, height: Int) {
        var background = [Bool](repeating: false, count: width * height)
        var queue = [Int]()
        queue.reserveCapacity(width * 2 + height * 2)

        func isNeutral(_ index: Int) -> Bool {
            let offset = index * 4
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            return max(red, green, blue) - min(red, green, blue) <= 30
        }

        func enqueue(_ index: Int) {
            guard !background[index], isNeutral(index) else { return }
            background[index] = true
            queue.append(index)
        }

        for x in 0..<width {
            enqueue(x)
            enqueue((height - 1) * width + x)
        }
        for y in 0..<height {
            enqueue(y * width)
            enqueue(y * width + width - 1)
        }

        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let x = index % width
            let y = index / width
            if x > 0 { enqueue(index - 1) }
            if x + 1 < width { enqueue(index + 1) }
            if y > 0 { enqueue(index - width) }
            if y + 1 < height { enqueue(index + width) }
        }

        for index in queue {
            let offset = index * 4
            pixels[offset] = 255
            pixels[offset + 1] = 255
            pixels[offset + 2] = 255
        }
    }
}

private struct Line {
    let slope: Double
    let intercept: Double

    func value(at coordinate: Double) -> Double { slope * coordinate + intercept }
}

private struct RectangleEdges {
    let left: Line
    let right: Line
    let top: Line
    let bottom: Line
}

private enum BackgroundWhiteningError: LocalizedError {
    case cannotReadImage
    case cannotWriteImage

    var errorDescription: String? {
        switch self {
        case .cannotReadImage: "Не удалось открыть скан для обработки фона."
        case .cannotWriteImage: "Не удалось сохранить скан с белым фоном."
        }
    }
}
