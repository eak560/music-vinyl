import SwiftUI

/// A slow, blurred colour field drawn from the cover art, behind a frosted pane.
///
/// The fluid feel comes from three things layered together: each colour is two
/// lobes drifting at different rates, so they merge and pull apart like liquid
/// rather than sliding as one rigid blob; the whole field turns very slowly;
/// and the wave bands are domain-warped — their phase is itself modulated by a
/// slower wave — which breaks up the tell-tale regularity of a plain sine.
///
/// It is all drawn in a single `Canvas`. The first version stacked ten blurred
/// `Circle` views with `.blendMode` and `.drawingGroup()`, which cost a full
/// offscreen composite plus a wide gaussian every frame and made
/// `GlassBackground.body` the hottest thing in the app at ~16% CPU — while the
/// music was *paused*. Radial gradients are already soft, so the blur was
/// buying almost nothing.
struct GlassBackground: View {
    let palette: [Color]
    /// Squared off in full screen, where rounded corners would just frame the
    /// display in black.
    var cornerRadius: CGFloat = 24
    /// Freezes the field. Scenery has no business burning a core while the
    /// record it sits behind is stopped, or while the window is not on screen.
    var paused: Bool = false

    private var colors: [Color] {
        palette.isEmpty
            ? [Color(red: 0.25, green: 0.28, blue: 0.42), Color(red: 0.38, green: 0.24, blue: 0.36)]
            : palette
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: paused)) { context in
            Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
                draw(in: ctx, size: size, time: context.date.timeIntervalSinceReferenceDate)
            }
        }
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
    }

    private func draw(in ctx: GraphicsContext, size: CGSize, time: TimeInterval) {
        let full = CGRect(origin: .zero, size: size)
        let diagonal = max(size.width, size.height)
        let anchor = colors[0]

        // Deep wash of the leading tint, so the field reads as coloured even
        // where the lobes thin out.
        ctx.fill(Path(full), with: .color(Color(white: 0.06)))
        ctx.fill(
            Path(full),
            with: .linearGradient(
                Gradient(colors: [anchor.opacity(0.30), anchor.opacity(0.14)]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: size.height)
            )
        )

        var field = ctx
        field.blendMode = .plusLighter
        field.opacity = 0.9

        // A gentle turn of the whole field, on top of each lobe's own drift.
        let swirl = 14 * sin(time * 0.024)
        field.translateBy(x: size.width / 2, y: size.height / 2)
        field.rotate(by: .degrees(swirl))
        field.translateBy(x: -size.width / 2, y: -size.height / 2)

        for (index, color) in colors.prefix(5).enumerated() {
            let i = Double(index)
            // Two lobes of the same colour, on deliberately mismatched orbits.
            for lobe in 0..<2 {
                let l = Double(lobe)
                let speed = 0.13 + i * 0.028 + l * 0.041
                let phase = i * 1.7 + l * 3.1
                let x = sin(time * speed + phase)
                let y = cos(time * (speed * 0.82 + 0.021) + phase * 1.3)
                let breathe = 1.0 + 0.26 * sin(time * (0.11 + i * 0.03 + l * 0.02) + phase)
                let pulse = 0.72 + 0.28 * sin(time * (0.09 + l * 0.033) + i * 2.2)

                let centre = CGPoint(
                    x: size.width / 2 + CGFloat(x) * size.width * (0.30 + CGFloat(l) * 0.07),
                    y: size.height / 2 + CGFloat(y) * size.height * (0.28 + CGFloat(l) * 0.06)
                )
                let radius = diagonal * CGFloat(0.30 + l * 0.06) * CGFloat(breathe)

                field.fill(
                    Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                           width: radius * 2, height: radius * 2)),
                    with: .radialGradient(
                        // Eased falloff rather than two stops: a linear alpha
                        // ramp bands visibly once the wide blur that used to
                        // hide it is gone.
                        Gradient(stops: [
                            .init(color: color.opacity(0.85 * pulse), location: 0),
                            .init(color: color.opacity(0.55 * pulse), location: 0.35),
                            .init(color: color.opacity(0.22 * pulse), location: 0.62),
                            .init(color: color.opacity(0.06 * pulse), location: 0.82),
                            .init(color: color.opacity(0), location: 1)
                        ]),
                        center: centre, startRadius: 0, endRadius: radius
                    )
                )
            }
        }

        // Three domain-warped bands, for the sense of something moving under
        // the glass. Warping the phase with a second, slower wave keeps them
        // from reading as a plain sine sliding sideways.
        var bands = ctx
        bands.blendMode = .plusLighter
        // The bands are the one hard-edged thing here — a sine boundary with a
        // gradient under it. Blurring just this layer costs far less than the
        // full-surface blur the old view-based version used.
        bands.addFilter(.blur(radius: 18))
        for band in 0..<3 {
            let b = Double(band)
            let phase = time * (0.42 + b * 0.17) + b * 2.1
            let warpPhase = time * (0.19 + b * 0.06)
            let baseline = size.height * CGFloat(0.42 + b * 0.17)
            let swell = 1.0 + 0.35 * sin(time * (0.13 + b * 0.05) + b)
            let amplitude = size.height * CGFloat((0.05 + b * 0.018) * swell)

            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: baseline))
            var x: CGFloat = 0
            while x <= size.width {
                let p = Double(x / max(size.width, 1))
                let warp = 0.75 * sin(p * .pi * 1.3 - warpPhase)
                path.addLine(to: CGPoint(x: x, y: baseline + amplitude * CGFloat(sin(p * .pi * 2.4 + phase + warp))))
                x += 8
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()

            let tint = colors[(band + 1) % colors.count]
            bands.fill(
                path,
                with: .linearGradient(
                    Gradient(colors: [tint.opacity(0.20), tint.opacity(0)]),
                    startPoint: CGPoint(x: 0, y: baseline),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }
    }
}
