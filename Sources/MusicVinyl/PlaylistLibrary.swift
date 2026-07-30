import AppKit
import Foundation

struct MusicPlaylist: Identifiable, Equatable {
    var id: String
    var name: String
}

struct PlaylistTrack: Identifiable, Equatable {
    /// Position in the playlist, 1-based — Music addresses tracks by index.
    var id: Int
    var title: String
    var artist: String
}

/// Reads the user's playlists out of Music.app and starts playback from them.
///
/// Properties are fetched in bulk (`name of every user playlist`) rather than by
/// looping in AppleScript: a loop costs one Apple event per property per row,
/// which on a real library takes seconds.
@MainActor
final class PlaylistLibrary: ObservableObject {
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published private(set) var tracks: [PlaylistTrack] = []
    @Published private(set) var isLoading = false
    @Published var selected: MusicPlaylist?

    private var hasLoaded = false

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        reload()
    }

    func reload() {
        hasLoaded = true
        isLoading = true
        MusicBridge.shared.fetchPlaylists { [weak self] result in
            guard let self else { return }
            self.playlists = result
            self.isLoading = false
        }
    }

    func select(_ playlist: MusicPlaylist) {
        selected = playlist
        tracks = []
        isLoading = true
        MusicBridge.shared.fetchTracks(inPlaylistWithID: playlist.id) { [weak self] result in
            guard let self, self.selected?.id == playlist.id else { return }
            self.tracks = result
            self.isLoading = false
        }
    }

    func deselect() {
        selected = nil
        tracks = []
    }
}

extension MusicBridge {
    /// Every user playlist, minus folders and Music's built-in special lists.
    func fetchPlaylists(_ completion: @escaping ([MusicPlaylist]) -> Void) {
        guard isMusicRunning else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        runScript("""
        tell application id "com.apple.Music"
            return {(name of every user playlist whose special kind is none), ¬
                    (persistent ID of every user playlist whose special kind is none)}
        end tell
        """) { result in
            guard let result, result.numberOfItems >= 2,
                  let names = result.atIndex(1), let ids = result.atIndex(2)
            else {
                completion([])
                return
            }
            var playlists: [MusicPlaylist] = []
            for index in 1...max(names.numberOfItems, 0) {
                guard let name = names.atIndex(index)?.stringValue,
                      let id = ids.atIndex(index)?.stringValue,
                      !name.isEmpty
                else { continue }
                playlists.append(MusicPlaylist(id: id, name: name))
            }
            completion(playlists)
        }
    }

    func fetchTracks(inPlaylistWithID id: String, _ completion: @escaping ([PlaylistTrack]) -> Void) {
        guard isMusicRunning else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        runScript("""
        tell application id "com.apple.Music"
            set theList to (first playlist whose persistent ID is "\(escape(id))")
            return {(name of every track of theList), (artist of every track of theList)}
        end tell
        """) { result in
            guard let result, result.numberOfItems >= 2,
                  let titles = result.atIndex(1), let artists = result.atIndex(2)
            else {
                completion([])
                return
            }
            var tracks: [PlaylistTrack] = []
            for index in 1...max(titles.numberOfItems, 0) {
                guard let title = titles.atIndex(index)?.stringValue else { continue }
                tracks.append(
                    PlaylistTrack(id: index,
                                  title: title,
                                  artist: artists.atIndex(index)?.stringValue ?? "")
                )
            }
            completion(tracks)
        }
    }

    func playPlaylist(id: String) {
        perform("play (first playlist whose persistent ID is \"\(escape(id))\")")
    }

    /// Plays one track *within* its playlist, so what follows is the rest of it.
    func playTrack(at index: Int, inPlaylistWithID id: String) {
        perform("play (track \(index) of (first playlist whose persistent ID is \"\(escape(id))\"))")
    }

    /// Persistent IDs are hex, but never build a script out of unescaped text.
    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
