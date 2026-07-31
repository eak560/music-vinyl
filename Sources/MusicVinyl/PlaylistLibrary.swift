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
    var album: String
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
    /// Covers for the rows on screen, filled in as they scroll into view —
    /// fetching every track's art up front would mean hundreds of lookups.
    @Published private(set) var artwork: [Int: NSImage] = [:]
    private var requested: Set<Int> = []

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
        artwork = [:]
        requested = []
        pendingArtwork.values.forEach { $0.cancel() }
        pendingArtwork = [:]
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
        artwork = [:]
        requested = []
        pendingArtwork.values.forEach { $0.cancel() }
        pendingArtwork = [:]
    }

    private var pendingArtwork: [Int: DispatchWorkItem] = [:]

    /// Asks for one row's cover. Cheap to call repeatedly: already-requested
    /// rows are skipped, and CatalogArtwork dedupes by album underneath, so a
    /// playlist that walks one record does a single lookup.
    ///
    /// Briefly deferred, because the wheel reports every entry it passes over:
    /// spinning through a few hundred tracks would otherwise fire a lookup for
    /// each one. Anything already cached still resolves immediately once the
    /// request goes out.
    func requestArtwork(for track: PlaylistTrack) {
        guard !requested.contains(track.id), pendingArtwork[track.id] == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingArtwork[track.id] = nil
            self?.startArtworkRequest(for: track)
        }
        pendingArtwork[track.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func startArtworkRequest(for track: PlaylistTrack) {
        guard !requested.contains(track.id) else { return }
        requested.insert(track.id)
        var probe = Track()
        probe.title = track.title
        probe.artist = track.artist
        probe.album = track.album
        probe.id = "playlist-\(selected?.id ?? "")-\(track.id)"
        CatalogArtwork.shared.fetchArtwork(for: probe) { [weak self] image in
            guard let self, let image else { return }
            self.artwork[track.id] = image
        }
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
            return {(name of every track of theList), (artist of every track of theList), ¬
                    (album of every track of theList)}
        end tell
        """) { result in
            guard let result, result.numberOfItems >= 3,
                  let titles = result.atIndex(1), let artists = result.atIndex(2),
                  let albums = result.atIndex(3)
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
                                  artist: artists.atIndex(index)?.stringValue ?? "",
                                  album: albums.atIndex(index)?.stringValue ?? "")
                )
            }
            completion(tracks)
        }
    }

    func playPlaylist(id: String) {
        perform("play (first playlist whose persistent ID is \"\(escape(id))\")")
    }

    /// Plays one track out of a playlist.
    ///
    /// Note this leaves Music with *no* current playlist — verified: after it,
    /// `name of current playlist` fails with -1728 and `next track` silently
    /// does nothing. Referencing the playlist by name or as a `user playlist`,
    /// revealing the track first, and playing the playlist beforehand were all
    /// tried; every form that plays a track object drops the context. So the
    /// model keeps its own queue instead — see `NowPlayingModel.playFromQueue`.
    func playTrack(at index: Int, inPlaylistWithID id: String, completion: (() -> Void)? = nil) {
        perform("play (track \(index) of (first playlist whose persistent ID is \"\(escape(id))\"))",
                completion: completion)
    }

    /// Persistent IDs are hex, but never build a script out of unescaped text.
    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
