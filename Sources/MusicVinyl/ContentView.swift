import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: NowPlayingModel
    @State private var hovering = false
    /// Last pointer angle during a drag, in degrees; nil when not dragging.
    @State private var dragAngle: Double?

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                ZStack {
                    // TimelineView drives the spin; it idles when nothing is playing.
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !model.state.isPlaying)) { context in
                        VinylView(
                            artwork: model.artwork,
                            angle: model.angle(at: context.date),
                            title: model.track.title,
                            artist: model.track.artist
                        )
                    }

                    TonearmView(
                        progress: model.progress,
                        engaged: armEngaged,
                        onTap: { model.toggleArm() }
                    )

                }
                // Only the record itself responds to grabbing.
                .contentShape(Circle())
                .gesture(discDrag(in: geo.size))
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(6)

            if model.showTrackInfo {
                trackInfo
            }

            // Always laid out, only faded — appearing and disappearing would
            // resize everything above it on every hover.
            TransportControls()
                .opacity(controlsVisible ? 1 : 0)
                .scaleEffect(controlsVisible ? 1 : 0.96)
                .allowsHitTesting(controlsVisible)
        }
        .padding(14)
        .animation(.easeOut(duration: 0.18), value: controlsVisible)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .background {
            if model.glassBackground {
                GlassBackground(palette: model.palette)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: model.glassBackground)
        .background(WindowConfigurator(alwaysOnTop: model.alwaysOnTop))
    }

    private var controlsVisible: Bool { hovering && !model.isScrubbing }

    /// The needle is down exactly when the music is moving — so pausing from
    /// anywhere, including Music itself, lifts the arm. It stays down through a
    /// scrub, since a hand on the record doesn't raise the tonearm.
    private var armEngaged: Bool {
        model.state.isPlaying || model.isScrubbing
    }

    /// Grabbing the record stops playback and turns it by hand; the playback
    /// position follows the rotation, so dragging back and forth scrubs.
    private func discDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 * VinylView.discScale

                if dragAngle == nil {
                    // Ignore presses that land outside the disc.
                    guard hypot(value.startLocation.x - center.x,
                                value.startLocation.y - center.y) <= radius else { return }
                    dragAngle = Self.angle(of: value.startLocation, around: center)
                    model.beginScrub()
                }

                guard let previous = dragAngle else { return }
                let current = Self.angle(of: value.location, around: center)
                var delta = current - previous
                // Unwrap across the ±180° seam.
                if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
                dragAngle = current
                model.updateScrub(deltaDegrees: delta)
            }
            .onEnded { _ in
                if dragAngle != nil { model.endScrub() }
                dragAngle = nil
            }
    }

    private static func angle(of point: CGPoint, around center: CGPoint) -> Double {
        atan2(point.y - center.y, point.x - center.x) * 180 / .pi
    }

    private var trackInfo: some View {
        VStack(spacing: 2) {
            Text(primaryLine)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if !model.track.artist.isEmpty {
                Text(model.track.artist)
                    .font(.system(size: 11.5))
                    .opacity(0.7)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
        .frame(maxWidth: 300)
        .padding(.bottom, 2)
    }

    private var primaryLine: String {
        switch model.state {
        case .notRunning: return "Music isn’t running"
        case .stopped: return "Nothing playing"
        default: return model.track.title.isEmpty ? "Nothing playing" : model.track.title
        }
    }

    @ViewBuilder private var menu: some View {
        Toggle("Always on Top", isOn: $model.alwaysOnTop)
        Toggle("Show Track Info", isOn: $model.showTrackInfo)
        Toggle("Glass Background", isOn: $model.glassBackground)
        Toggle("Look Up Artwork Online", isOn: $model.onlineArtwork)
        Divider()
        Picker("Speed", selection: $model.rpm) {
            Text("33⅓ RPM").tag(33.3333)
            Text("45 RPM").tag(45.0)
            Text("78 RPM").tag(78.0)
        }
        Divider()
        Button("Open Music") { MusicBridge.shared.activateMusic() }
        Button("Quit") { NSApp.terminate(nil) }
    }
}

/// Play/pause and skip, revealed on hover over the record.
private struct TransportControls: View {
    @EnvironmentObject private var model: NowPlayingModel

    var body: some View {
        HStack(spacing: 22) {
            button("backward.fill") { model.previous() }
            button(model.state.isPlaying ? "pause.fill" : "play.fill", size: 22) { model.playPause() }
            button("forward.fill") { model.next() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
    }

    private func button(_ symbol: String, size: CGFloat = 17, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size + 12, height: size + 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Strips the window chrome so only the record is visible, and keeps the
/// floating level in sync with the user's preference.
struct WindowConfigurator: NSViewRepresentable {
    let alwaysOnTop: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // `.hiddenTitleBar` hides the title and buttons but keeps the titlebar,
        // and macOS draws a hairline under it. On an opaque window that is
        // invisible; on this transparent one it reads as a stray line across
        // the top. Let the content run edge to edge instead.
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.level = alwaysOnTop ? .floating : .normal
        window.collectionBehavior.insert(.fullScreenAuxiliary)
    }
}
