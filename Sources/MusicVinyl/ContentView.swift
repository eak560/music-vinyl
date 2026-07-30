import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: NowPlayingModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 10) {
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

                TonearmView(progress: model.progress, engaged: model.state != .stopped && model.state != .notRunning)

                if hovering {
                    TransportControls()
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .padding(6)

            if model.showTrackInfo {
                trackInfo
            }
        }
        .padding(14)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .background(WindowConfigurator(alwaysOnTop: model.alwaysOnTop))
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
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.level = alwaysOnTop ? .floating : .normal
        window.collectionBehavior.insert(.fullScreenAuxiliary)
    }
}
