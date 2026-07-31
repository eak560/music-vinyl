import AppKit
import Foundation

/// Development helper: `MusicVinyl --queue-test` picks a track out of a
/// playlist the way the browser does, then checks that next and previous still
/// move — the case where Music's own transport does nothing, because playing a
/// lone track leaves it with no current playlist.
enum QueueTest {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Thread.detachNewThread { body() }
        app.run()
        exit(0)
    }

    private static var failures = 0

    private static func body() {
        let model = onMain { NowPlayingModel() }
        let library = onMain { PlaylistLibrary() }
        onMain { library.reload() }
        guard waitUntil({ onMain { !library.playlists.isEmpty } }) else {
            print("SKIP: no playlists"); exit(1)
        }
        let playlist = onMain { library.playlists.first { $0.name.count > 4 } ?? library.playlists[0] }
        onMain { library.select(playlist) }
        guard waitUntil({ onMain { library.tracks.count > 3 } }) else {
            print("SKIP: playlist too short"); exit(1)
        }
        let tracks = onMain { library.tracks }
        print("playlist: \(playlist.name) (\(tracks.count) tracks)")

        let start = 3
        onMain { model.playFromQueue(playlistID: playlist.id, index: start, count: tracks.count) }
        // Wait for the track to actually change rather than guessing at a delay.
        _ = waitUntil({ onMain { model.track.title } == tracks[start - 1].title }, timeout: 10)
        check("picked track \(start) plays", onMain { model.track.title } == tracks[start - 1].title,
              "want \(tracks[start - 1].title), got \(onMain { model.track.title })")

        print("  queue=\(onMain { model.queue.map { "\($0.index)/\($0.count)" } ?? "nil" }) " +
              "musicPlaylist=\(onMain { model.track.playlist.isEmpty ? "<none>" : model.track.playlist })")
        onMain { model.next() }
        _ = waitUntil({ onMain { model.track.title } == tracks[start].title }, timeout: 10)
        print("  after next: queue=\(onMain { model.queue.map { "\($0.index)/\($0.count)" } ?? "nil" })")
        check("next advances", onMain { model.track.title } == tracks[start].title,
              "want \(tracks[start].title), got \(onMain { model.track.title })")

        onMain { model.previous() }
        _ = waitUntil({ onMain { model.track.title } == tracks[start - 1].title }, timeout: 10)
        print("  after prev: queue=\(onMain { model.queue.map { "\($0.index)/\($0.count)" } ?? "nil" })")
        check("previous goes back", onMain { model.track.title } == tracks[start - 1].title,
              "want \(tracks[start - 1].title), got \(onMain { model.track.title })")

        onMain { MusicBridge.shared.pause() }
        Thread.sleep(forTimeInterval: 0.5)
        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 12) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func onMain<T>(_ work: @MainActor @escaping () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated { work() } }
    }

    private static func check(_ label: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL")  \(label)\(passed ? "" : "  [\(detail())]")")
    }
}
