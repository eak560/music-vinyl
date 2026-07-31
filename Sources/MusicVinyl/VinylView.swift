import AppKit
import SwiftUI

/// The record: a static vinyl body (grooves are rotationally symmetric, so they
/// never need to move) with a rotating label and a rotating specular streak that
/// makes the spin readable even when there is no artwork.
struct VinylView: View {
    let artwork: NSImage?
    let angle: Double
    let title: String
    let artist: String
    /// The cover being replaced, and how far the blend between them has run.
    var previousArtwork: NSImage? = nil
    var artworkFade: Double = 1
    var style: DiscStyle = .classic

    /// The platter takes up less than the full square so the tonearm pivot has
    /// somewhere to live outside the record.
    static let discScale: CGFloat = 0.84

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * Self.discScale
            ZStack {
                switch style {
                case .classic:
                    DiscBody(side: side).equatable()
                case .picture:
                    // Cover across the whole face, with the grooves cut over it.
                    coverFace(side: side)
                        .clipShape(Circle())
                        .rotationEffect(.degrees(angle))
                    Grooves(side: side, style: style).equatable()
                case .glass:
                    // Clear pressing: the cover sits under a translucent disc,
                    // so it reads as tinted rather than printed.
                    coverFace(side: side)
                        .clipShape(Circle())
                        .rotationEffect(.degrees(angle))
                        .opacity(0.34)
                        .saturation(0.75)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [.white.opacity(0.16), .white.opacity(0.05), .white.opacity(0.22)],
                                center: .topLeading, startRadius: 0, endRadius: side
                            )
                        )
                    Grooves(side: side, style: style).equatable()
                    Circle().strokeBorder(.white.opacity(0.35), lineWidth: max(0.6, side * 0.004))
                }

                // Rotating sheen — a faint bright wedge sweeping the surface.
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [
                                .white.opacity(0.0), .white.opacity(0.05), .white.opacity(0.0),
                                .white.opacity(0.0), .white.opacity(0.03), .white.opacity(0.0)
                            ],
                            center: .center
                        )
                    )
                    .rotationEffect(.degrees(angle))
                    .blendMode(.screen)

                if style == .classic {
                    LabelView(
                        artwork: artwork,
                        previousArtwork: previousArtwork,
                        fade: artworkFade,
                        side: side,
                        title: title,
                        artist: artist
                    )
                    .frame(width: side * 0.34, height: side * 0.34)
                    .rotationEffect(.degrees(angle))
                }

                // Fixed highlight from a light above-left, plus the spindle.
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.14), .clear, .clear, .white.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.softLight)

                Circle()
                    .fill(Color.black.opacity(0.9))
                    .frame(width: side * 0.026, height: side * 0.026)
                    .overlay(
                        Circle().strokeBorder(.white.opacity(0.18), lineWidth: max(0.5, side * 0.0018))
                    )
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .shadow(color: .black.opacity(0.55), radius: side * 0.045, x: 0, y: side * 0.018)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// The cover, cross-faded, sized to cover the whole disc. Used by the
    /// picture and clear styles, where the art is the record rather than a
    /// label stuck to it.
    @ViewBuilder
    private func coverFace(side: CGFloat) -> some View {
        ZStack {
            Color(white: 0.08)
            cover(previousArtwork, side: side)
            cover(artwork, side: side).opacity(artworkFade)
        }
    }

    @ViewBuilder
    private func cover(_ image: NSImage?, side: CGFloat) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
        }
    }
}

/// Groove rings drawn over whatever face is underneath. Rotationally symmetric,
/// so they never need to turn.
private struct Grooves: View, Equatable {
    let side: CGFloat
    let style: DiscStyle

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func circle(_ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            }

            let inner = radius * 0.20
            let outer = radius * 0.965
            let line = max(0.5, radius * 0.0035)
            // On a printed face the grooves read as shadow; on a clear one they
            // catch the light instead.
            let dark = style == .picture
            for i in 0..<130 {
                let f = Double(i) / 129
                let r = inner + (outer - inner) * f
                let strength = 0.05 + 0.06 * abs(sin(f * 26))
                ctx.stroke(circle(r),
                           with: .color(dark ? .black.opacity(strength) : .white.opacity(strength)),
                           lineWidth: line)
            }
            for f in [0.18, 0.37, 0.55, 0.72, 0.88] as [Double] {
                let r = inner + (outer - inner) * f
                ctx.stroke(circle(r), with: .color(.black.opacity(0.28)), lineWidth: line * 2.4)
            }
            ctx.stroke(circle(radius * 0.985), with: .color(.white.opacity(0.18)), lineWidth: line * 1.4)
        }
    }

    static func == (lhs: Grooves, rhs: Grooves) -> Bool {
        lhs.side == rhs.side && lhs.style == rhs.style
    }
}

/// The black disc and its grooves. Depends only on the size, so SwiftUI can skip
/// redrawing it on every animation frame.
private struct DiscBody: View, Equatable {
    let side: CGFloat

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            func circle(_ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            }

            // Body.
            ctx.fill(
                circle(radius),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: Color(white: 0.13), location: 0.0),
                        .init(color: Color(white: 0.08), location: 0.55),
                        .init(color: Color(white: 0.05), location: 0.88),
                        .init(color: Color(white: 0.10), location: 1.0)
                    ]),
                    center: center, startRadius: 0, endRadius: radius
                )
            )

            // Grooves.
            // Grooves start just outside the label and stop shy of the edge.
            let inner = radius * 0.365
            let outer = radius * 0.965
            let count = 130
            let line = max(0.5, radius * 0.0035)
            for i in 0..<count {
                let f = Double(i) / Double(count - 1)
                let r = inner + (outer - inner) * f
                let shimmer = 0.035 + 0.045 * abs(sin(f * 26))
                ctx.stroke(circle(r), with: .color(.white.opacity(shimmer)), lineWidth: line)
            }

            // Gaps between tracks read as slightly wider dark bands.
            for f in [0.18, 0.37, 0.55, 0.72, 0.88] as [Double] {
                let r = inner + (outer - inner) * f
                ctx.stroke(circle(r), with: .color(.black.opacity(0.55)), lineWidth: line * 2.6)
            }

            // Lead-in and run-out edges.
            ctx.stroke(circle(radius * 0.985), with: .color(.white.opacity(0.16)), lineWidth: line * 1.4)
            ctx.stroke(circle(radius * 0.352), with: .color(.black.opacity(0.7)), lineWidth: line * 3)
        }
    }

    static func == (lhs: DiscBody, rhs: DiscBody) -> Bool { lhs.side == rhs.side }
}

/// Center label: album art when Music has it, otherwise a printed paper label.
///
/// Draws the outgoing face underneath and the incoming one over it at `fade`
/// opacity, which handles every combination — cover to cover, cover to printed
/// label, and back — with one blend and no view identity games.
private struct LabelView: View {
    let artwork: NSImage?
    let previousArtwork: NSImage?
    let fade: Double
    let side: CGFloat
    let title: String
    let artist: String

    var body: some View {
        ZStack {
            face(previousArtwork)
            face(artwork).opacity(fade)
        }
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.black.opacity(0.45), lineWidth: max(0.5, side * 0.0035)))
        .overlay(
            // Spindle hole punched through the label.
            Circle()
                .fill(Color.black)
                .frame(width: side * 0.026, height: side * 0.026)
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        )
        .shadow(color: .black.opacity(0.4), radius: side * 0.01)
    }

    /// One side of the blend: a cover if there is one, the printed label if not.
    @ViewBuilder
    private func face(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RadialGradient(
                    colors: [Color(red: 0.85, green: 0.78, blue: 0.65), Color(red: 0.62, green: 0.53, blue: 0.42)],
                    center: .center, startRadius: 0, endRadius: side * 0.22
                )
                // Spaced so the spindle hole falls in the gap between the lines.
                VStack(spacing: side * 0.055) {
                    Text(title.isEmpty ? "No Music Playing" : title)
                        .font(.system(size: side * 0.026, weight: .semibold, design: .serif))
                    if !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: side * 0.021, weight: .regular, design: .serif))
                            .opacity(0.75)
                    }
                }
                .foregroundStyle(Color(red: 0.16, green: 0.12, blue: 0.09))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, side * 0.045)
                Circle()
                    .strokeBorder(Color.black.opacity(0.18), lineWidth: max(0.5, side * 0.002))
                    .padding(side * 0.02)
            }
        }
    }
}

/// A stylized tonearm that tracks inward as the song progresses. Clicking it
/// lifts the needle off the record, or drops it back on.
struct TonearmView: View {
    /// 0...1 through the current track.
    let progress: Double
    /// When false the arm swings back to its rest position.
    let engaged: Bool
    let onTap: () -> Void

    // Pivot sits just off the top-right corner of the platter. The angles below
    // are tuned against `VinylView.discScale` so the stylus lands on the
    // outermost groove at 0% and just outside the label at 100%.
    private static let pivotU = CGPoint(x: 0.90, y: 0.13)
    private static let restAngle: Double = 6
    private static let leadIn: Double = -5
    private static let runOut: Double = -25

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let pivot = CGPoint(x: side * Self.pivotU.x, y: side * Self.pivotU.y)
            let armLength = side * 0.62
            let rotation = engaged
                ? Self.leadIn + (Self.runOut - Self.leadIn) * progress
                : Self.restAngle

            ZStack {
                // Arm, drawn horizontally with its right end on the pivot, then
                // swung about that pivot.
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.86), Color(white: 0.52), Color(white: 0.74)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: armLength, height: side * 0.017)
                    .overlay(alignment: .leading) {
                        // Headshell carrying the stylus.
                        RoundedRectangle(cornerRadius: side * 0.007)
                            .fill(
                                LinearGradient(
                                    colors: [Color(white: 0.30), Color(white: 0.16)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            .frame(width: side * 0.070, height: side * 0.036)
                            .offset(x: -side * 0.020)
                    }
                    // Widen the hit area well past the visual thickness — the
                    // arm is only a few points tall but needs to be clickable.
                    .padding(.vertical, side * 0.022)
                    .contentShape(Capsule())
                    .onTapGesture(perform: onTap)
                    .position(x: pivot.x - armLength / 2, y: pivot.y)

                // Counterweight behind the pivot.
                Capsule()
                    .fill(Color(white: 0.28))
                    .frame(width: side * 0.055, height: side * 0.042)
                    .position(x: pivot.x + side * 0.045, y: pivot.y)

                // Pivot base.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(white: 0.78), Color(white: 0.32)],
                            center: .topLeading, startRadius: 0, endRadius: side * 0.07
                        )
                    )
                    .frame(width: side * 0.085, height: side * 0.085)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                    .position(pivot)
            }
            .frame(width: side, height: side)
            .rotationEffect(
                .degrees(rotation),
                anchor: UnitPoint(x: Self.pivotU.x, y: Self.pivotU.y)
            )
            .shadow(color: .black.opacity(0.45), radius: side * 0.012, x: side * 0.004, y: side * 0.012)
            .animation(.easeInOut(duration: 0.9), value: engaged)
            .animation(.linear(duration: 1.0), value: progress)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
