import SwiftUI

/// Transport keys in the style of a cassette deck: chunky cream keys in a dark
/// housing, with the glyphs drawn as shapes rather than set in a symbol font, so
/// they keep the blunt geometry of the moulded originals at any size.
struct RetroTransport: View {
    @EnvironmentObject private var model: NowPlayingModel
    let onPlaylists: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            key(.rewind) { model.previous() }
            key(model.state.isPlaying ? .pause : .play, wide: true) { model.playPause() }
            key(.forward) { model.next() }
            key(.stack, action: onPlaylists)
            key(.sliders, action: onSettings)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(housing)
    }

    private var housing: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.20), Color(white: 0.11)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
    }

    private func key(_ glyph: TransportGlyph, wide: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TransportGlyphShape(glyph: glyph)
                .fill(Color(red: 0.16, green: 0.15, blue: 0.14))
                .frame(width: wide ? 17 : 14, height: 13)
                .frame(width: wide ? 42 : 34, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyStyle())
    }
}

/// A key that visibly travels when pressed, like a mechanical one.
private struct KeyStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: pressed
                                ? [Color(white: 0.72), Color(white: 0.80)]
                                : [Color(white: 0.93), Color(white: 0.78)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.white.opacity(hovering ? 0.9 : 0.5), lineWidth: 0.8)
                    )
                    // The key sits in a recess; the shadow is what sells the
                    // travel when it drops.
                    .shadow(color: .black.opacity(pressed ? 0.2 : 0.55),
                            radius: pressed ? 1 : 2.5,
                            y: pressed ? 0.5 : 2)
            )
            .offset(y: pressed ? 1.5 : 0)
            .onHover { hovering = $0 }
    }
}

enum TransportGlyph {
    case play, pause, rewind, forward, stack, sliders
}

/// The moulded key faces: solid triangles and bars, no strokes.
struct TransportGlyphShape: Shape {
    let glyph: TransportGlyph

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch glyph {
        case .play:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()

        case .pause:
            let barWidth = rect.width * 0.32
            path.addRect(CGRect(x: rect.minX, y: rect.minY, width: barWidth, height: rect.height))
            path.addRect(CGRect(x: rect.maxX - barWidth, y: rect.minY, width: barWidth, height: rect.height))

        case .forward, .rewind:
            // Two triangles, mirrored for rewind.
            let half = rect.width * 0.46
            for index in 0..<2 {
                let x = rect.minX + CGFloat(index) * (rect.width - half)
                var triangle = Path()
                triangle.move(to: CGPoint(x: x, y: rect.minY))
                triangle.addLine(to: CGPoint(x: x + half, y: rect.midY))
                triangle.addLine(to: CGPoint(x: x, y: rect.maxY))
                triangle.closeSubpath()
                path.addPath(triangle)
            }
            if glyph == .rewind {
                path = path.applying(
                    CGAffineTransform(translationX: rect.midX, y: 0)
                        .scaledBy(x: -1, y: 1)
                        .translatedBy(x: -rect.midX, y: 0)
                )
            }

        case .stack:
            // Three stacked bars, as on a track-select key.
            let barHeight = rect.height * 0.18
            for index in 0..<3 {
                let y = rect.minY + CGFloat(index) * (rect.height - barHeight) / 2
                path.addRect(CGRect(x: rect.minX, y: y, width: rect.width, height: barHeight))
            }

        case .sliders:
            // Two rails with a travelling knob each — a deck's trim controls.
            // A cog was tried first and read as an asterisk: filling an outer
            // and inner ellipse with the default non-zero winding paints a
            // solid disc rather than a ring.
            let railHeight = rect.height * 0.10
            let knob = CGSize(width: rect.width * 0.20, height: rect.height * 0.34)
            for (index, position) in [0.62, 0.28].enumerated() {
                let centerY = rect.minY + rect.height * (index == 0 ? 0.28 : 0.72)
                path.addRect(CGRect(x: rect.minX, y: centerY - railHeight / 2,
                                    width: rect.width, height: railHeight))
                path.addRoundedRect(
                    in: CGRect(x: rect.minX + (rect.width - knob.width) * position,
                               y: centerY - knob.height / 2,
                               width: knob.width, height: knob.height),
                    cornerSize: CGSize(width: 1, height: 1)
                )
            }
        }
        return path
    }
}
