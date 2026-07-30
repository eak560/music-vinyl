import AppKit
import SwiftUI

/// Pulls a handful of representative colours out of the cover art, used to tint
/// the animated background.
enum Palette {
    /// Covers skew dark, and a background built straight from their colours
    /// comes out near-black. Lift each tint to a usable brightness and rein in
    /// the extremes of saturation, keeping the hue — which is what actually
    /// reads as "this album's colour".
    private static func normalized(_ color: NSColor) -> NSColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getHue(&hue, saturation: &saturation,
                                             brightness: &brightness, alpha: &alpha)
        return NSColor(hue: hue,
                       saturation: min(max(saturation, 0.45), 0.85),
                       brightness: min(max(brightness, 0.62), 0.9),
                       alpha: 1)
    }

    /// Extraction is cheap but not free; do it off the main thread.
    static func extract(from image: NSImage, maxCount: Int = 5) -> [Color] {
        guard let counts = histogram(of: image) else { return [] }

        struct Candidate {
            var color: NSColor
            var hue: CGFloat
            var score: Double
        }

        var candidates: [Candidate] = []
        for (_, bucket) in counts {
            let color = bucket.averageColor
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

            // Skip near-black, blown-out white and washed-out greys: they make
            // for a muddy background and carry no identity.
            guard brightness > 0.14, brightness < 0.97, saturation > 0.18 else { continue }

            // Weight by how much of the cover it occupies, but favour saturated
            // colours so a large beige wall doesn't beat the actual accent.
            candidates.append(
                Candidate(color: color, hue: hue, score: Double(bucket.count) * Double(0.35 + saturation))
            )
        }

        candidates.sort { $0.score > $1.score }

        // Keep the picks visibly distinct rather than five shades of one hue.
        var chosen: [Candidate] = []
        for candidate in candidates {
            let tooClose = chosen.contains { existing in
                let delta = abs(existing.hue - candidate.hue)
                return min(delta, 1 - delta) < 0.055
            }
            if !tooClose { chosen.append(candidate) }
            if chosen.count == maxCount { break }
        }

        // A cover with almost no saturated area still deserves a background.
        if chosen.isEmpty, let dominant = counts.values.max(by: { $0.count < $1.count }) {
            return [Color(nsColor: normalized(dominant.averageColor))]
        }
        return chosen.map { Color(nsColor: normalized($0.color)) }
    }

    private struct Bucket {
        var count = 0
        var red = 0.0, green = 0.0, blue = 0.0

        mutating func add(r: Double, g: Double, b: Double) {
            count += 1
            red += r
            green += g
            blue += b
        }

        var averageColor: NSColor {
            let n = Double(max(count, 1))
            return NSColor(srgbRed: red / n / 255, green: green / n / 255, blue: blue / n / 255, alpha: 1)
        }
    }

    /// Downsamples the cover and bins pixels into a coarse RGB grid.
    private static func histogram(of image: NSImage) -> [Int: Bucket]? {
        let side = 40
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let pixels = rep.bitmapData else { return nil }

        var buckets: [Int: Bucket] = [:]
        for index in stride(from: 0, to: side * side * 4, by: 4) {
            let r = Double(pixels[index])
            let g = Double(pixels[index + 1])
            let b = Double(pixels[index + 2])
            guard pixels[index + 3] > 8 else { continue }
            // 5 bits per channel: enough to separate hues, coarse enough that
            // gradients collapse into one entry.
            let key = (Int(r) >> 3) << 10 | (Int(g) >> 3) << 5 | (Int(b) >> 3)
            buckets[key, default: Bucket()].add(r: r, g: g, b: b)
        }
        return buckets
    }
}
