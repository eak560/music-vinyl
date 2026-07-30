import AppKit
import Foundation

/// Last-resort artwork source for Apple Music streaming tracks.
///
/// Music exposes no artwork at all for `URL track`s (streaming songs that are
/// not in the library) — `count of artworks` stays 0 for the whole song — and
/// MediaRemote, which the system's own now-playing UI uses, has been restricted
/// to Apple-signed binaries since macOS 15.4. So the only way to put a real
/// cover on the record is to look it up.
///
/// This is the one part of the app that touches the network. It runs only after
/// the local AppleScript route has come back empty, and only while the user
/// leaves "Look Up Artwork Online" enabled.
final class CatalogArtwork {
    static let shared = CatalogArtwork()

    private let session: URLSession
    /// Keyed by track id. `nil` marks a lookup that failed, so a track with no
    /// match is not re-requested on every retry tick.
    private var cache: [String: NSImage?] = [:]

    private init() {
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

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(track.artist) \(track.title)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components.url else {
            completion(nil)
            return
        }

        let id = track.id
        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = payload["results"] as? [[String: Any]],
                  let artworkURL = Self.bestArtworkURL(in: results, for: track)
            else {
                DispatchQueue.main.async {
                    self?.remember(nil, for: id)
                    completion(nil)
                }
                return
            }

            self?.session.dataTask(with: artworkURL) { imageData, _, _ in
                let image = imageData.flatMap(NSImage.init(data:))
                DispatchQueue.main.async {
                    self?.remember(image, for: id)
                    completion(image)
                }
            }.resume()
        }.resume()
    }

    private func remember(_ image: NSImage?, for id: String) {
        cache[id] = image
    }

    /// Case, accents and qualifiers like "(Radio Edit)" or "- Single" vary
    /// between what Music reports and what the catalogue lists; none of them
    /// change which song it is.
    private static func normalize(_ value: String) -> String {
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

    /// Picks the result that actually matches the playing song, rather than
    /// trusting the search ranking — a wrong cover is worse than none.
    private static func bestArtworkURL(in results: [[String: Any]], for track: Track) -> URL? {
        func matches(_ lhs: String?, _ rhs: String) -> Bool {
            guard let lhs, !rhs.isEmpty else { return false }
            return normalize(lhs) == normalize(rhs)
        }

        // The title must match. Matching only the artist would happily accept a
        // different song by the same act — which is exactly how a cover from
        // elsewhere in the same album ends up on the record.
        let titleMatches = results.filter { matches($0["trackName"] as? String, track.title) }

        let scored = titleMatches.map { result -> (Int, [String: Any]) in
            var score = 0
            if matches(result["artistName"] as? String, track.artist) { score += 2 }
            if matches(result["collectionName"] as? String, track.album) { score += 2 }
            return (score, result)
        }

        // Still require corroboration from the artist or the album.
        guard let best = scored.max(by: { $0.0 < $1.0 }), best.0 >= 2,
              let raw = best.1["artworkUrl100"] as? String
        else { return nil }

        // The API hands back a 100px thumbnail; the same path serves larger
        // sizes, and the record label is rendered well above 100px.
        return URL(string: raw.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
            ?? URL(string: raw)
    }
}
