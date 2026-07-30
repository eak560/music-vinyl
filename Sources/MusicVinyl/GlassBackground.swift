import SwiftUI

/// A slow, blurred colour field drawn from the cover art, behind a frosted pane.
///
/// The fluid feel comes from three things layered together: each colour is two
/// lobes drifting at different rates, so they merge and pull apart like liquid
/// rather than sliding as one rigid blob; the whole field turns very slowly;
/// and the wave bands are domain-warped — their phase is itself modulated by a
/// slower wave — which breaks up the tell-tale regularity of a plain sine.
///
/// Every period is incommensurate with the others, so the motion never visibly
/// loops. It runs at 30fps: it is scenery, and a heavily blurred layer at 60fps
/// is a waste of the GPU.
struct GlassBackground: View {
    let palette: [Color]
    /// Squared off in full screen, where rounded corners would just frame the
    /// display in black.
    var cornerRadius: CGFloat = 24

    private var colors: [Color] {
        palette.isEmpty
            ? [Color(red: 0.25, green: 0.28, blue: 0.42), Color(red: 0.38, green: 0.24, blue: 0.36)]
            : palette
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let size = geo.size
                ZStack {
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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(cornerRadius > 0 ? 0.12 : 0), lineWidth: 1)
        )
        .drawingGroup()
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

    /// Where a given lobe sits, and how wide its falloff is, at this instant.
    private struct Lobe {
        var color: Color
        var offset: CGSize
        var radius: CGFloat
        var opacity: Double
    }

    private func lobes(time: TimeInterval, size: CGSize) -> [Lobe] {
        let diagonal: CGFloat = max(size.width, size.height)
        var result: [Lobe] = []

        for (index, color) in colors.prefix(5).enumerated() {
            let i = Double(index)
            // Two lobes of the same colour, on deliberately mismatched orbits.
            for lobe in 0..<2 {
                let l = Double(lobe)
                let speed: Double = 0.13 + i * 0.028 + l * 0.041
                let phase: Double = i * 1.7 + l * 3.1
                let xDrift: Double = sin(time * speed + phase)
                let yDrift: Double = cos(time * (speed * 0.82 + 0.021) + phase * 1.3)
                let breathe: Double = 1.0 + 0.26 * sin(time * (0.11 + i * 0.03 + l * 0.02) + phase)
                // Lobes fade in and out of each other rather than holding a
                // fixed weight, which is most of what sells the liquid look.
                let pulse: Double = 0.72 + 0.28 * sin(time * (0.09 + l * 0.033) + i * 2.2)

                result.append(
                    Lobe(
                        color: color,
                        offset: CGSize(
                            width: CGFloat(xDrift) * size.width * (0.30 + CGFloat(l) * 0.07),
                            height: CGFloat(yDrift) * size.height * (0.28 + CGFloat(l) * 0.06)
                        ),
                        radius: diagonal * CGFloat(0.30 + l * 0.06) * CGFloat(breathe),
                        opacity: pulse
                    )
                )
            }
        }
        return result
    }

    /// Soft colour clouds drifting on lissajous paths.
    private func blobs(time: TimeInterval, size: CGSize) -> some View {
        let diagonal: CGFloat = max(size.width, size.height)
        let frames: [Lobe] = lobes(time: time, size: size)
        let swirl: Double = 14 * sin(time * 0.024)

        return ZStack {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, lobe in
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [lobe.color.opacity(0.85), lobe.color.opacity(0.0)],
                            center: .center, startRadius: 0, endRadius: lobe.radius
                        )
                    )
                    .frame(width: diagonal * 0.9, height: diagonal * 0.9)
                    .offset(lobe.offset)
                    .opacity(lobe.opacity)
                    .blendMode(.plusLighter)
            }
        }
        .rotationEffect(.degrees(swirl))
        .blur(radius: diagonal * 0.055)
        .opacity(0.9)
    }

    /// Three domain-warped bands, for the sense of something moving under the
    /// glass. Warping the phase with a second, slower wave keeps them from
    /// reading as a plain sine sliding sideways.
    private func waves(time: TimeInterval, size: CGSize) -> some View {
        Canvas { context, canvasSize in
            for band in 0..<3 {
                let b = Double(band)
                let phase: Double = time * (0.42 + b * 0.17) + b * 2.1
                let warpPhase: Double = time * (0.19 + b * 0.06)
                let baseline: CGFloat = canvasSize.height * CGFloat(0.42 + b * 0.17)
                let swell: Double = 1.0 + 0.35 * sin(time * (0.13 + b * 0.05) + b)
                let amplitude: CGFloat = canvasSize.height * CGFloat((0.05 + b * 0.018) * swell)

                var path = Path()
                path.move(to: CGPoint(x: 0, y: canvasSize.height))
                path.addLine(to: CGPoint(x: 0, y: baseline))
                var x: CGFloat = 0
                while x <= canvasSize.width {
                    let p = Double(x / max(canvasSize.width, 1))
                    let warp: Double = 0.75 * sin(p * .pi * 1.3 - warpPhase)
                    let y = baseline + amplitude * CGFloat(sin(p * .pi * 2.4 + phase + warp))
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 5
                }
                path.addLine(to: CGPoint(x: canvasSize.width, y: canvasSize.height))
                path.closeSubpath()

                let tint = colors[(band + 1) % colors.count]
                context.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [tint.opacity(0.20), tint.opacity(0.0)]),
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
