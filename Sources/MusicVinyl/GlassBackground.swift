import SwiftUI

/// A slow, blurred colour field drawn from the cover art, behind a frosted pane.
///
/// Everything drifts on incommensurate periods so the motion never visibly
/// loops, and the whole thing runs at 24fps — it is scenery, and a heavily
/// blurred layer at 60fps is a waste of the GPU.
struct GlassBackground: View {
    let palette: [Color]

    private var colors: [Color] {
        palette.isEmpty
            ? [Color(red: 0.25, green: 0.28, blue: 0.42), Color(red: 0.38, green: 0.24, blue: 0.36)]
            : palette
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    // A deep tint of the album's own colour, rather than grey,
                    // so the field reads as coloured even where blobs thin out.
                    base

                    blobs(time: time, size: size)
                    waves(time: time, size: size)
                }
                .frame(width: size.width, height: size.height)
            }
        }
        // Hand-rolled glass rather than .ultraThinMaterial: the window is
        // transparent, so a system material samples whatever is on the desktop
        // behind it and the look changes with the wallpaper.
        .overlay(Rectangle().fill(.white.opacity(0.05)))
        .overlay(
            LinearGradient(
                colors: [.white.opacity(0.10), .clear, .black.opacity(0.16)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .drawingGroup()
    }

    /// Where a given blob sits, and how wide its falloff is, at this instant.
    private struct BlobFrame {
        var color: Color
        var offset: CGSize
        var radius: CGFloat
    }

    private func blobFrames(time: TimeInterval, size: CGSize) -> [BlobFrame] {
        let diagonal: CGFloat = max(size.width, size.height)
        return colors.prefix(5).enumerated().map { index, color in
            let i = Double(index)
            let xDrift: Double = sin(time * (0.045 + i * 0.011) + i * 1.7)
            let yDrift: Double = cos(time * (0.037 + i * 0.013) + i * 2.3)
            let breathe: Double = 1.0 + 0.14 * sin(time * (0.05 + i * 0.017) + i)
            return BlobFrame(
                color: color,
                offset: CGSize(width: CGFloat(xDrift) * size.width * 0.32,
                               height: CGFloat(yDrift) * size.height * 0.30),
                radius: diagonal * 0.34 * CGFloat(breathe)
            )
        }
    }

    /// Soft colour clouds drifting on lissajous paths.
    private func blobs(time: TimeInterval, size: CGSize) -> some View {
        let diagonal: CGFloat = max(size.width, size.height)
        let frames: [BlobFrame] = blobFrames(time: time, size: size)
        return ZStack {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [frame.color.opacity(0.85), frame.color.opacity(0.0)],
                            center: .center, startRadius: 0, endRadius: frame.radius
                        )
                    )
                    .frame(width: diagonal * 0.9, height: diagonal * 0.9)
                    .offset(frame.offset)
                    .blendMode(.plusLighter)
            }
        }
        .blur(radius: diagonal * 0.055)
        .opacity(0.9)
    }

    /// Deep, desaturated wash of the leading tint.
    private var base: some View {
        let anchor = colors[0]
        return LinearGradient(
            colors: [anchor.opacity(0.30), anchor.opacity(0.14)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .background(Color(white: 0.06))
    }

    /// Two lazy sine bands, for the sense of something moving under the glass.
    private func waves(time: TimeInterval, size: CGSize) -> some View {
        Canvas { context, canvasSize in
            for band in 0..<2 {
                let phase = time * (0.20 + Double(band) * 0.09) + Double(band) * 2.1
                let baseline = canvasSize.height * (0.52 + Double(band) * 0.16)
                let amplitude = canvasSize.height * (0.045 + Double(band) * 0.02)

                var path = Path()
                path.move(to: CGPoint(x: 0, y: canvasSize.height))
                path.addLine(to: CGPoint(x: 0, y: baseline))
                var x: CGFloat = 0
                while x <= canvasSize.width {
                    let progress = Double(x / max(canvasSize.width, 1))
                    let y = baseline + amplitude * sin(progress * .pi * 2.4 + phase)
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 6
                }
                path.addLine(to: CGPoint(x: canvasSize.width, y: canvasSize.height))
                path.closeSubpath()

                let tint = colors[(band + 1) % colors.count]
                context.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [tint.opacity(0.22), tint.opacity(0.0)]),
                        startPoint: CGPoint(x: 0, y: baseline),
                        endPoint: CGPoint(x: 0, y: canvasSize.height)
                    )
                )
            }
        }
        .blur(radius: 14)
        .blendMode(.plusLighter)
    }
}
