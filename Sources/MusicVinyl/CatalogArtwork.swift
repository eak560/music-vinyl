import AppKit
import CryptoKit
import Foundation

/// Artwork source for Apple Music streaming tracks.
///
/// Music exposes no artwork at all for some `URL track`s, and a cover from an
/// entirely different release for others, so streaming tracks are looked up
/// here instead. MediaRemote, which the system's own now-playing UI uses, has
/// been restricted to Apple-signed binaries since macOS 15.4.
///
/// This is the one part of the app that touches the network. Library tracks
/// never reach it, and the user can switch it off entirely.
final class CatalogArtwork {
    static let shared = CatalogArtwork()

    private let session: URLSession
    /// Keyed by track id. `nil` marks a lookup that failed, so a track with no
    /// match is not re-requested on every retry tick.
    private var cache: [String: NSImage?] = [:]
    private var cacheOrder: [String] = []
    /// Keyed by artist + album. Consecutive tracks from one album share a
    /// cover, so the second onwards resolve with no network at all.
    private var albumCache: [String: NSImage] = [:]
    private var albumOrder: [String] = []
    /// Both caches are bounded. Scrolling a long playlist asks for a cover per
    /// row, and a 600×600 cover costs well over a megabyte once decoded, so
    /// keeping every one browsed in a session grew without limit.
    private static let memoryLimit = 24
    /// Survives relaunches, so a cover is fetched once ever rather than once
    /// per session.
    private let diskDirectory: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        diskDirectory = (caches ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("MusicVinyl/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)

        // Ephemeral: no cookie jar, no on-disk URL cache, nothing persisted.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: config)
    }

    /// Completion always runs on the main queue.
    func fetchArtwork(for track: Track, completion: @escaping (NSImage?) -> Void) {
        if let cached = cache[track.id] {
            completion(cached)
            return
        }
        guard !track.title.isEmpty || !track.artist.isEmpty else {
            completion(nil)
            return
        }

        let id = track.id
        let album = Self.albumKey(for: track)

        // An album already seen this session — the common case when a playlist
        // walks through one record.
        if let known = albumCache[album] {
            finish(known, for: id, completion: completion)
            return
        }

        // ...or seen in an earlier session. Read off the main thread: this runs
        // while the wheel is being scrolled, and a stall here is a dropped
        // frame in the middle of a gesture.
        let url = diskURL(for: album)
        Self.diskQueue.async { [weak self] in
            let cached = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                guard let self else { return }
                if let cached {
                    self.remember(cached, forAlbum: album)
                    self.finish(cached, for: id, completion: completion)
                } else {
                    self.search(for: track, id: id, album: album, completion: completion)
                }
            }
        }
    }

    private static let diskQueue = DispatchQueue(label: "com.ehsan.musicvinyl.artwork-disk",
                                                 qos: .userInitiated)

    private func search(for track: Track, id: String, album: String,
                        completion: @escaping (NSImage?) -> Void) {
        // Pass 1: the track itself.
        search(term: "\(track.artist) \(track.title)",
               pick: { Self.trackMatch(in: $0, for: track) }) { [weak self] url in
            guard let self else { return }
            if let url {
                self.download(url, for: id, album: album, completion: completion)
                return
            }
            // Pass 2: the album it came from. Apple's search index does not
            // surface every track — "Japanese Denim" is absent entirely, and a
            // title search returns only instrumental covers by other artists —
            // but the album is usually there, and its cover is what Music shows
            // anyway.
            guard !track.album.isEmpty else {
                self.finish(nil, for: id, completion: completion)
                return
            }
            self.search(term: "\(track.artist) \(track.album)",
                        pick: { Self.albumMatch(in: $0, for: track) }) { albumURL in
                guard let albumURL else {
                    self.finish(nil, for: id, completion: completion)
                    return
                }
                self.download(albumURL, for: id, album: album, completion: completion)
            }
        }
    }

    // MARK: - Requests

    private func search(term: String,
                        pick: @escaping ([[String: Any]]) -> URL?,
                        completion: @escaping (URL?) -> Void) {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            // The wanted result is often well down the ranking.
            URLQueryItem(name: "limit", value: "25")
        ]
        guard let url = components.url else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        session.dataTask(with: url) { data, _, _ in
            var results: [[String: Any]] = []
            if let data,
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rows = payload["results"] as? [[String: Any]] {
                results = rows
            }
            let match = pick(results)
            DispatchQueue.main.async { completion(match) }
        }.resume()
    }

    private func download(_ url: URL, for id: String, album: String,
                          completion: @escaping (NSImage?) -> Void) {
        session.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                guard let self else { return }
                if let image, let data {
                    self.remember(image, forAlbum: album)
                    // Store the bytes as delivered; re-encoding would be lossy
                    // and slower for no gain. Written off the main thread for
                    // the same reason the read is.
                    let url = self.diskURL(for: album)
                    Self.diskQueue.async { try? data.write(to: url, options: .atomic) }
                }
                self.finish(image, for: id, completion: completion)
            }
        }.resume()
    }

    /// Covers are per album, not per track.
    private static func albumKey(for track: Track) -> String {
        let album = normalize(track.album)
        let subject = album.isEmpty ? normalize(track.title) : album
        return normalize(track.artist) + "|" + subject
    }

    private func diskURL(for albumKey: String) -> URL {
        let digest = SHA256.hash(data: Data(albumKey.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(name)
    }

    private func finish(_ image: NSImage?, for id: String, completion: @escaping (NSImage?) -> Void) {
        if cache[id] == nil { cacheOrder.append(id) }
        cache[id] = image
        trim(&cacheOrder, limit: Self.memoryLimit * 4) { self.cache.removeValue(forKey: $0) }
        completion(image)
    }

    private func remember(_ image: NSImage, forAlbum key: String) {
        if albumCache[key] == nil { albumOrder.append(key) }
        albumCache[key] = image
        trim(&albumOrder, limit: Self.memoryLimit) { self.albumCache.removeValue(forKey: $0) }
    }

    /// Drops the oldest keys once the list outgrows its limit.
    private func trim(_ order: inout [String], limit: Int, remove: (String) -> Void) {
        guard order.count > limit else { return }
        let excess = order.count - limit
        for key in order.prefix(excess) { remove(key) }
        order.removeFirst(excess)
    }

    // MARK: - Matching

    /// Case, accents and qualifiers like "(Radio Edit)" or "- Single" vary
    /// between what Music reports and what the catalogue lists; none of them
    /// change which song it is.
    static func normalize(_ value: String) -> String {
        var text = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        text = text.replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s-\\s(single|ep|deluxe|remaster).*$",
                                         with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "\\bfeat\\.?\\s.*$",
                                         with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func matches(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs, !rhs.isEmpty else { return false }
        return normalize(lhs) == normalize(rhs)
    }

    /// A result for this exact song. The title must match — matching only the
    /// artist would accept a different song by the same act, which is how a
    /// cover from elsewhere in the same catalogue ends up on the record.
    static func trackMatch(in results: [[String: Any]], for track: Track) -> URL? {
        let titled = results.filter { matches($0["trackName"] as? String, track.title) }
        let scored = titled.map { result -> (Int, [String: Any]) in
            var score = 0
            if matches(result["artistName"] as? String, track.artist) { score += 2 }
            if matches(result["collectionName"] as? String, track.album) { score += 2 }
            return (score, result)
        }
        // Still require corroboration from the artist or the album, so a cover
        // version by an unrelated act can't supply the image.
        guard let best = scored.max(by: { $0.0 < $1.0 }), best.0 >= 2 else { return nil }
        return artworkURL(from: best.1)
    }

    /// Any track from the right album by the right artist — its artwork is the
    /// album cover, which is what Music displays.
    static func albumMatch(in results: [[String: Any]], for track: Track) -> URL? {
        let match = results.first {
            matches($0["artistName"] as? String, track.artist)
                && matches($0["collectionName"] as? String, track.album)
        }
        return match.flatMap(artworkURL(from:))
    }

    private static func artworkURL(from result: [String: Any]) -> URL? {
        guard let raw = result["artworkUrl100"] as? String else { return nil }
        // The API hands back a 100px thumbnail; the same path serves larger
        // sizes, and the record label is rendered well above 100px.
        return URL(string: raw.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
            ?? URL(string: raw)
    }
}
