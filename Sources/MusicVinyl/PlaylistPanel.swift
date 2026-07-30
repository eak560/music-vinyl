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

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let selected = library.selected {
                    ForEach(library.tracks) { track in
                        row(title: track.title,
                            subtitle: track.artist,
                            highlighted: isNowPlaying(track)) {
                            MusicBridge.shared.playTrack(at: track.id, inPlaylistWithID: selected.id)
                            refreshSoon()
                        }
                    }
                } else {
                    ForEach(library.playlists) { playlist in
                        row(title: playlist.name,
                            subtitle: nil,
                            highlighted: playlist.name == model.track.playlist,
                            trailing: "chevron.right") {
                            library.select(playlist)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.automatic)
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
