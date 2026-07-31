import SwiftUI

/// Slides up over the record: the user's Music playlists, and the tracks inside
/// whichever one they open. Picking a track plays it *within* its playlist, so
/// what follows is the rest of the list rather than a dead end.
struct PlaylistPanel: View {
    @EnvironmentObject private var model: NowPlayingModel
    @ObservedObject var library: PlaylistLibrary
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))

            if library.isLoading && rowCount == 0 {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            } else if rowCount == 0 {
                Spacer()
                Text(model.state == .notRunning ? "Music isn’t running" : "No playlists")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            } else {
                list
            }
        }
        .background(.black.opacity(0.55))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }

    private var rowCount: Int {
        library.selected == nil ? library.playlists.count : library.tracks.count
    }

    private var header: some View {
        HStack(spacing: 8) {
            if library.selected != nil {
                Button {
                    library.deselect()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }

            Text(library.selected?.name ?? "Playlists")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if let selected = library.selected {
                Button {
                    MusicBridge.shared.playPlaylist(id: selected.id)
                    refreshSoon()
                } label: {
                    Image(systemName: "play.fill").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Play this playlist")
            }

            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// ImageRenderer does not materialise ScrollView content, so the dev render
    /// flag bypasses the scroll view to check row layout.
    private static let rendersFlat = ProcessInfo.processInfo.environment["VINYL_NO_SCROLL"] != nil

    @ViewBuilder
    private var list: some View {
        if Self.rendersFlat {
            listBody
        } else {
            ScrollView { listBody }.scrollIndicators(.automatic)
        }
    }

    private var listBody: some View {
        Group {
            if let selected = library.selected {
                // Tracks are shown as a leaning stack of sleeves rather than
                // text rows — the cover is the thing worth recognising.
                LazyVStack(spacing: -34) {
                    ForEach(library.tracks) { track in
                        SleeveCard(
                            title: track.title,
                            artist: track.artist,
                            artwork: library.artwork[track.id],
                            playing: isNowPlaying(track)
                        ) {
                            MusicBridge.shared.playTrack(at: track.id, inPlaylistWithID: selected.id)
                            refreshSoon()
                        }
                        .onAppear { library.requestArtwork(for: track) }
                    }
                }
                .padding(.top, 26)
                .padding(.bottom, 40)
                .padding(.horizontal, 14)
            } else {
                playlistRows
            }
        }
    }

    private var playlistRows: some View {
        LazyVStack(spacing: 0) {
            ForEach(library.playlists) { playlist in
                row(title: playlist.name,
                    subtitle: nil,
                    highlighted: playlist.name == model.track.playlist,
                    trailing: "chevron.right") {
                    library.select(playlist)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func isNowPlaying(_ track: PlaylistTrack) -> Bool {
        track.title == model.track.title && track.artist == model.track.artist
    }

    @ViewBuilder
    private func row(title: String,
                     subtitle: String?,
                     highlighted: Bool,
                     trailing: String? = nil,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: highlighted ? .semibold : .regular))
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .opacity(0.6)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if highlighted {
                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 9))
                } else if let trailing {
                    Image(systemName: trailing).font(.system(size: 9)).opacity(0.35)
                }
            }
            .foregroundStyle(.white.opacity(highlighted ? 1 : 0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    /// Playback takes a moment to settle; nudge the model so the record and the
    /// now-playing marker catch up without waiting for the next poll.
    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.refresh() }
    }
}

private struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Rectangle()
                    .fill(.white.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.08 : 0)))
            )
            .onHover { hovering = $0 }
    }
}

/// One record in the leaning stack: the cover, tilted back in perspective, with
/// a title strip across it.
private struct SleeveCard: View {
    let title: String
    let artist: String
    let artwork: NSImage?
    let playing: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // The cover goes in the background rather than a ZStack layer: at
            // .fill it overflows, and a ZStack would size itself to the
            // overflowing image, pushing the strip outside the visible crop.
            VStack(spacing: 0) {
                strip
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 128)
            .background { cover }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(playing ? 0.7 : 0.16), lineWidth: playing ? 1.5 : 0.8)
            )
            .shadow(color: .black.opacity(0.55), radius: 9, y: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Laid back like sleeves in a crate. Hovering lifts one out.
        .rotation3DEffect(
            .degrees(hovering ? 40 : 54),
            axis: (x: 1, y: 0, z: 0),
            anchor: .center,
            perspective: 0.62
        )
        .scaleEffect(hovering ? 1.04 : 1)
        .zIndex(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var cover: some View {
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
        } else {
            LinearGradient(
                colors: [Color(white: 0.26), Color(white: 0.14)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    private var strip: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
            Text(artist)
                .font(.system(size: 12))
                .opacity(0.8)
                .lineLimit(1)
            Spacer(minLength: 0)
            if playing {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 10))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.42))
    }
}
