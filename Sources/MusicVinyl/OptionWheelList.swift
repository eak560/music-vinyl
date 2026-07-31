import AppKit
import SwiftUI

/// Tracks laid out around a circle anchored to the left edge, the way a
/// physical selector wheel reads: the entry in the middle is sharp and bright,
/// and its neighbours fall away in opacity and focus as they curl off.
///
/// Scroll, drag or click to turn it. Clicking an entry plays it.
struct OptionWheelList: View {
    let items: [String]
    let subtitles: [String]
    /// Index currently playing, drawn with a marker.
    var nowPlaying: Int?
    let onPlay: (Int) -> Void

    private let fontSize: CGFloat = 16
    private let spacing: CGFloat = 1.9
    private let tiltDegrees: Double = 6
    private let curve: Double = 0.55
    private let blurPerStep: Double = 1.5
    private let fadePerStep: Double = 0.24
    private let minOpacity: Double = 0.05
    private let inset: CGFloat = 26
    /// Entries beyond this are invisible anyway; not drawing them keeps a
    /// several-hundred-track playlist cheap.
    private let window = 7

    @State private var position: Double = 0
    @State private var dragOrigin: Double?
    @State private var snapWork: DispatchWorkItem?

    private var rowHeight: Double { Double(fontSize) * Double(spacing) }
    private var tiltRadians: Double { tiltDegrees * .pi / 180 }
    /// Radius that keeps the arc between neighbours exactly one row tall.
    private var radius: Double { rowHeight / tiltRadians }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                ForEach(visibleIndices, id: \.self) { index in
                    entry(index, width: max(80, geo.size.width - inset - 14))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // ImageRenderer draws an NSViewRepresentable as a placeholder block, so
        // the dev render flag leaves the catcher out.
        .background {
            if ProcessInfo.processInfo.environment["VINYL_NO_SCROLL"] == nil {
                ScrollCatcher { delta in turn(by: -Double(delta) / rowHeight) }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let origin = dragOrigin ?? position
                    if dragOrigin == nil { dragOrigin = origin }
                    position = clamp(origin - Double(value.translation.height) / rowHeight)
                }
                .onEnded { _ in
                    dragOrigin = nil
                    snap()
                }
        )
        .onAppear { position = Double(nowPlaying ?? 0) }
        .onChange(of: nowPlaying) { _, new in
            guard let new else { return }
            withAnimation(.easeOut(duration: 0.35)) { position = Double(new) }
        }
    }

    private var visibleIndices: [Int] {
        let centre = Int(position.rounded())
        let lower = max(0, centre - window)
        let upper = min(items.count - 1, centre + window)
        guard lower <= upper else { return [] }
        return Array(lower...upper)
    }

    @ViewBuilder
    private func entry(_ index: Int, width: CGFloat) -> some View {
        let d = Double(index) - position
        let distance = abs(d)
        let angle = min(max(d * tiltRadians, -.pi / 2), .pi / 2)
        let y = radius * sin(angle)
        let x = -radius * (1 - cos(angle)) * curve
        // 1 at the centre, 0 a full step away — drives colour and weight.
        let p = max(0, 1 - min(distance, 1))

        HStack(spacing: 8) {
            if nowPlaying == index {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 9))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(items[index])
                    .font(.system(size: fontSize, weight: p > 0.5 ? .medium : .light))
                    .lineLimit(1)
                if !subtitles[index].isEmpty {
                    Text(subtitles[index])
                        .font(.system(size: 10))
                        .opacity(0.55 * p)
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(Color(white: 0.65).blended(with: .white, amount: p))
        // Long titles are truncated rather than left to run off the panel.
        .frame(width: width, alignment: .leading)
        .rotationEffect(.degrees(angle * 180 / .pi), anchor: .leading)
        .offset(x: inset + x, y: y)
        .opacity(max(minOpacity, 1 - distance * fadePerStep))
        .blur(radius: distance * blurPerStep)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.3)) { position = Double(index) }
            onPlay(index)
        }
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), Double(max(items.count - 1, 0)))
    }

    private func turn(by steps: Double) {
        // One notch of a mouse wheel should move one entry, while a trackpad
        // still glides.
        position = clamp(position + min(max(steps, -1), 1))
        snap()
    }

    /// Settle onto whole entries once the input stops.
    private func snap() {
        snapWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.22)) { position = position.rounded() }
        }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }
}

/// SwiftUI has no scroll-wheel modifier on macOS, so this hands the deltas over
/// from an AppKit view sitting behind the wheel.
struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView { CatcherView(onScroll: onScroll) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: (CGFloat) -> Void

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func scrollWheel(with event: NSEvent) {
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * 8
            onScroll(delta)
        }
    }
}
