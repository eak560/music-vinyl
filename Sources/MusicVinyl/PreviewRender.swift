import AppKit
import SwiftUI

/// Development helper: `MusicVinyl --render-preview <out.png>` renders the record
/// offscreen and exits, so the artwork can be checked without launching a window.
enum PreviewRender {
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { SelfTest.run() }
        // Renders the real panel with the real library, so layout problems show
        // up without needing to click anything.
        if let flag = args.firstIndex(of: "--render-playlists") {
            let path = args.count > flag + 1 ? args[flag + 1] : "playlists.png"
            let model = NowPlayingModel()
            let library = PlaylistLibrary()
            library.reload()
            Pump.wait(timeout: 10) { !library.playlists.isEmpty }
            if ProcessInfo.processInfo.environment["PREVIEW_TRACKS"] != nil,
               let first = library.playlists.first(where: { $0.name.count > 4 }) ?? library.playlists.first {
                library.select(first)
                Pump.wait(timeout: 10) { !library.tracks.isEmpty }
            }
            Pump.drain(0.4)
            print("state: playlists=\(library.playlists.count) tracks=\(library.tracks.count) " +
                  "loading=\(library.isLoading) selected=\(library.selected?.name ?? "-")")
            let scene = PlaylistPanel(library: library, onClose: {})
                .environmentObject(model)
                .padding(10)
                .frame(width: 380, height: 430)
                .background(Color(white: 0.1))
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 2
            guard let cg = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            else { exit(1) }
            try? data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            exit(0)
        }
        if args.contains("--playlists") {
            var lists: [MusicPlaylist]?
            MusicBridge.shared.fetchPlaylists { lists = $0 }
            Pump.wait(timeout: 20) { lists != nil }
            let playlists = lists ?? []
            print("playlists: \(playlists.count)")
            for playlist in playlists.prefix(6) { print("  \(playlist.name)  [\(playlist.id)]") }
            if let first = playlists.first {
                var tracks: [PlaylistTrack]?
                let started = Date()
                MusicBridge.shared.fetchTracks(inPlaylistWithID: first.id) { tracks = $0 }
                Pump.wait(timeout: 20) { tracks != nil }
                let rows = tracks ?? []
                print(String(format: "tracks in %@: %d in %.0f ms",
                             first.name, rows.count, Date().timeIntervalSince(started) * 1000))
                for row in rows.prefix(4) { print("  \(row.id). \(row.title) — \(row.artist)") }
            }
            exit(0)
        }
        // --lookup "<title>" "<artist>" "<album>" exercises the artwork search
        // for a track that isn't currently playing.
        if let flag = args.firstIndex(of: "--lookup") {
            var probe = Track()
            probe.title = args.count > flag + 1 ? args[flag + 1] : ""
            probe.artist = args.count > flag + 2 ? args[flag + 2] : ""
            probe.album = args.count > flag + 3 ? args[flag + 3] : ""
            probe.id = "probe"
            print("lookup: \(probe.title) / \(probe.artist) / \(probe.album)")
            var done = false
            let started = Date()
            CatalogArtwork.shared.fetchArtwork(for: probe) { image in
                let ms = Date().timeIntervalSince(started) * 1000
                print(String(format: "  result: %@ in %.0f ms",
                             image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none", ms))
                if let image, let path = ProcessInfo.processInfo.environment["DUMP_ARTWORK"],
                   let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("  wrote \(path)")
                }
                done = true
            }
            Pump.wait(timeout: 25) { done }
            exit(0)
        }

        if args.contains("--dump-state") {
            var read: Snapshot?
            MusicBridge.shared.fetchSnapshot { read = $0 }
            Pump.wait(timeout: 5) { read != nil }
            let snapshot = read ?? Snapshot(state: .notRunning)
            print("state: \(snapshot.state.rawValue)")
            print("title: \(snapshot.track.title)")
            print("artist: \(snapshot.track.artist)")
            print("album: \(snapshot.track.album)")
            print("position: \(snapshot.track.position) / \(snapshot.track.duration)")
            print("streaming: \(snapshot.track.isStreaming)")
            func describe(_ image: NSImage?) -> String {
                image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "none"
            }
            // Report both sources so it is obvious which one is carrying a
            // given track.
            // Report both sources unconditionally: which one the app would
            // actually use depends on whether the track is streaming.
            var finished = false
            MusicBridge.shared.fetchArtwork { image in
                print("artwork (local): \(describe(image))")
                let start = Date()
                CatalogArtwork.shared.fetchArtwork(for: snapshot.track) { online in
                    let ms = Date().timeIntervalSince(start) * 1000
                    print(String(format: "artwork (online): %@ in %.0f ms", describe(online), ms))
                    if let online, let data = online.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: data),
                       let png = rep.representation(using: .png, properties: [:]),
                       let path = ProcessInfo.processInfo.environment["DUMP_ARTWORK"] {
                        try? png.write(to: URL(fileURLWithPath: path))
                        print("wrote online artwork to \(path)")
                    }
                    finished = true
                }
            }
            Pump.wait(timeout: 20) { finished }
            exit(0)
        }
        // Mirrors ContentView's layout at an arbitrary size, to check that the
        // background fills a wide window rather than just the record's column.
        if let flag = args.firstIndex(of: "--render-layout") {
            let path = args.count > flag + 1 ? args[flag + 1] : "layout.png"
            let dims = (ProcessInfo.processInfo.environment["PREVIEW_SIZE"] ?? "1512x949")
                .split(separator: "x").compactMap { Double($0) }
            let size = CGSize(width: dims.first ?? 1512, height: dims.last ?? 949)
            let art = ProcessInfo.processInfo.environment["PREVIEW_ART"]
                .flatMap { NSImage(contentsOfFile: $0) }
            renderLayout(to: path, size: size, art: art)
        }
        if let flag = args.firstIndex(of: "--render-icon") {
            renderIcon(to: args.count > flag + 1 ? args[flag + 1] : "AppIcon.png")
        }
        guard let flag = args.firstIndex(of: "--render-preview") else { return }
        let path = args.count > flag + 1 ? args[flag + 1] : "vinyl-preview.png"
        let angle = Double(ProcessInfo.processInfo.environment["PREVIEW_ANGLE"] ?? "") ?? 24
        let progress = Double(ProcessInfo.processInfo.environment["PREVIEW_PROGRESS"] ?? "") ?? 0.35
        let withArt = ProcessInfo.processInfo.environment["PREVIEW_NOART"] == nil
        // PREVIEW_ART points at a real cover file; otherwise a stand-in is drawn.
        let suppliedArt = ProcessInfo.processInfo.environment["PREVIEW_ART"]
            .flatMap { NSImage(contentsOfFile: $0) }
        // PREVIEW_ART2 + PREVIEW_FADE show the cover cross-fade mid-blend.
        let outgoingArt = ProcessInfo.processInfo.environment["PREVIEW_ART2"]
            .flatMap { NSImage(contentsOfFile: $0) }
        let fade = Double(ProcessInfo.processInfo.environment["PREVIEW_FADE"] ?? "") ?? 1
        // PREVIEW_ARM=off shows the tonearm swung clear, as when it is lifted.
        let armEngaged = ProcessInfo.processInfo.environment["PREVIEW_ARM"] != "off"

        // PREVIEW_GLASS renders the animated colour background instead of a
        // flat backdrop, tinted by whatever cover was supplied.
        let glass = ProcessInfo.processInfo.environment["PREVIEW_GLASS"] != nil
        let palette = suppliedArt.map { Palette.extract(from: $0) } ?? []

        let side: CGFloat = 720
        let scene = ZStack {
            if glass {
                GlassBackground(palette: palette)
            } else {
                Color(white: 0.16)
            }
            ZStack {
                VinylView(
                    artwork: withArt ? (suppliedArt ?? sampleArtwork(side: 512)) : nil,
                    angle: angle,
                    title: "Midnight Ride",
                    artist: "The Long Players",
                    previousArtwork: outgoingArt,
                    artworkFade: fade
                )
                TonearmView(progress: progress, engaged: armEngaged, onTap: {})
            }
            .padding(20)
        }
        .frame(width: side, height: side)

        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        exit(0)
    }

    @MainActor
    private static func renderLayout(to path: String, size: CGSize, art: NSImage?) {
        let palette = art.map { Palette.extract(from: $0) } ?? []
        let scene = VStack(spacing: 10) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ZStack {
                        VinylView(artwork: art, angle: 20, title: "Midnight Ride", artist: "The Long Players")
                        TonearmView(progress: 0.2, engaged: true, onTap: {})
                    }
                }
                .padding(6)
            Text("Midnight Ride").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            Capsule().fill(.white.opacity(0.18)).frame(width: 190, height: 46)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlassBackground(palette: palette, cornerRadius: 0))
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: scene)
        renderer.scale = 1
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { exit(1) }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        exit(0)
    }

    /// Renders the 1024pt master image the .icns is built from.
    @MainActor
    private static func renderIcon(to path: String) {
        let side: CGFloat = 1024
        let scene = ZStack {
            VinylView(artwork: sampleArtwork(side: 512), angle: -18, title: "", artist: "")
            TonearmView(progress: 0.12, engaged: true, onTap: {})
        }
        .frame(width: side, height: side)
        .padding(side * 0.06)

        let renderer = ImageRenderer(content: scene)
        renderer.scale = 1
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { exit(1) }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        exit(0)
    }

    /// Stand-in album art so the label can be evaluated without Music running.
    private static func sampleArtwork(side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.95, green: 0.36, blue: 0.24, alpha: 1),
            NSColor(calibratedRed: 0.20, green: 0.15, blue: 0.45, alpha: 1)
        ])
        gradient?.draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: 45)
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(rect: NSRect(x: side * 0.12, y: side * 0.46, width: side * 0.76, height: side * 0.03)).fill()
        NSBezierPath(ovalIn: NSRect(x: side * 0.34, y: side * 0.60, width: side * 0.32, height: side * 0.32)).fill()
        image.unlockFocus()
        return image
    }
}
