import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: NowPlayingModel
    @State private var hovering = false
    /// Last pointer angle during a drag, in degrees; nil when not dragging.
    @State private var dragAngle: Double?
    @State private var isFullScreen = false
    @State private var showingPlaylists = false
    @State private var showingSettings = false
    @StateObject private var library = PlaylistLibrary()

    var body: some View {
        mainContent
            .overlay {
                if showingPlaylists {
                    PlaylistPanel(library: library) { withAnimation { showingPlaylists = false } }
                        .padding(isFullScreen ? 60 : 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if showingSettings {
                    SettingsPanel { withAnimation { showingSettings = false } }
                        .padding(isFullScreen ? 60 : 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.22), value: showingPlaylists)
            .animation(.easeOut(duration: 0.22), value: showingSettings)
    }

    private func togglePlaylists() {
        library.loadIfNeeded()
        withAnimation {
            showingSettings = false
            showingPlaylists.toggle()
        }
    }

    private func toggleSettings() {
        withAnimation {
            showingPlaylists = false
            showingSettings.toggle()
        }
    }

    private var mainContent: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                ZStack {
                    // TimelineView drives the spin; it idles when nothing is playing.
                    // Keeps running through a cover cross-fade even when the
                    // record is stopped, or the blend would freeze part-way.
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                            paused: !model.state.isPlaying && !model.isCrossFadingArtwork)) { context in
                        VinylView(
                            artwork: model.artwork,
                            angle: model.angle(at: context.date),
                            title: model.track.title,
                            artist: model.track.artist,
                            previousArtwork: model.previousArtwork,
                            artworkFade: model.artworkFade(at: context.date),
                            style: model.discStyle
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
            RetroTransport(onPlaylists: togglePlaylists, onSettings: toggleSettings)
                .opacity(controlsVisible ? 1 : 0)
                .scaleEffect(controlsVisible ? 1 : 0.96)
                .allowsHitTesting(controlsVisible)
        }
        .padding(isFullScreen ? 40 : 14)
        // The record is square, so on a wide window the stack is only as wide
        // as the disc — without this the background would paint that column
        // and leave the rest of the screen bare. Fill the window, then draw
        // behind it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: controlsVisible)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .background {
            if model.glassBackground {
                GlassBackground(palette: model.palette, cornerRadius: isFullScreen ? 0 : 24)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: model.glassBackground)
        .background(WindowConfigurator(alwaysOnTop: model.alwaysOnTop, isFullScreen: isFullScreen))
        .onAppear {
            // VINYL_FULLSCREEN_TEST exercises the real app's window, since the
            // menu item can't be clicked from a script.
            if ProcessInfo.processInfo.environment["VINYL_FULLSCREEN_TEST"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    WindowConfigurator.toggleFullScreen()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 7) { exit(0) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
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
            if !model.track.playlist.isEmpty {
                Label(model.track.playlist, systemImage: "music.note.list")
                    .font(.system(size: 10))
                    .opacity(0.55)
                    .lineLimit(1)
                    .padding(.top, 1)
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
        Button(showingPlaylists ? "Hide Playlists" : "Show Playlists") { togglePlaylists() }
        Button(showingSettings ? "Hide Turntable Settings" : "Turntable Settings…") { toggleSettings() }
        Button(isFullScreen ? "Exit Full Screen" : "Enter Full Screen") {
            WindowConfigurator.toggleFullScreen()
        }
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

/// Strips the window chrome so only the record is visible, and keeps the
/// floating level in sync with the user's preference.
struct WindowConfigurator: NSViewRepresentable {
    let alwaysOnTop: Bool
    var isFullScreen: Bool = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    /// Toggles the key window in or out of full screen.
    static func toggleFullScreen() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            Trace.log("toggleFullScreen: no window")
            return
        }
        // SwiftUI finishes configuring the window after our NSViewRepresentable
        // has run, and puts .fullScreenNone back. Since that flag is mutually
        // exclusive with .fullScreenPrimary, the window would just refuse to
        // toggle — so clear it here, immediately before it matters.
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.styleMask.insert(.resizable)

        Trace.log("""
        toggleFullScreen: primary=\(window.collectionBehavior.contains(.fullScreenPrimary)) \
        none=\(window.collectionBehavior.contains(.fullScreenNone)) level=\(window.level.rawValue)
        """)
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            Trace.log("after toggle: fullScreen=\(window.styleMask.contains(.fullScreen)) frame=\(window.frame)")
        }
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
        // A floating window sits above the full-screen space and breaks the
        // transition, so drop back to normal level while full screen.
        let fullScreen = window.styleMask.contains(.fullScreen)
        window.level = (alwaysOnTop && !fullScreen) ? .floating : .normal
        // SwiftUI marks this window .fullScreenNone, which is mutually
        // exclusive with .fullScreenPrimary — inserting primary while none is
        // still set is silently rejected, and the window simply refuses to go
        // full screen. Clear it first.
        //
        // fullScreenPrimary, not fullScreenAuxiliary: auxiliary only lets the
        // window ride along in another app's space, it can't have its own.
        window.collectionBehavior.remove(.fullScreenNone)
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.styleMask.insert(.resizable)
    }
}
