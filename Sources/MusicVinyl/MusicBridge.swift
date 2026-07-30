import AppKit
import Foundation

/// Playback state reported by Music.app.
enum PlayerState: String {
    case notRunning
    case stopped
    case playing
    case paused

    var isPlaying: Bool { self == .playing }
}

/// A snapshot of what Music.app is currently playing.
struct Track: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var duration: Double = 0
    var position: Double = 0
    var id: String = ""

    var isEmpty: Bool { title.isEmpty && artist.isEmpty }
}

struct Snapshot: Equatable {
    var state: PlayerState = .notRunning
    var track: Track = Track()
}

/// Talks to Music.app over Apple events. All AppleScript work happens on one
/// dedicated serial queue — `NSAppleScript` is not thread safe, but it is happy
/// as long as it is always driven from the same thread.
final class MusicBridge {
    static let shared = MusicBridge()

    static let bundleID = "com.apple.Music"

    private let queue = DispatchQueue(label: "com.ehsan.musicvinyl.applescript", qos: .userInitiated)

    // Note: short names like `st` and `th` are reserved ordinal tokens in
    // AppleScript, so the variables here are spelled out.
    private lazy var snapshotScript: NSAppleScript? = compile("""
    tell application id "com.apple.Music"
        set theState to (player state as text)
        if theState is "stopped" then return {theState, "", "", "", 0, 0, ""}
        set theTrack to current track
        return {theState, (name of theTrack as text), (artist of theTrack as text), ¬
                (album of theTrack as text), (duration of theTrack), (player position), ¬
                (persistent ID of theTrack as text)}
    end tell
    """)

    private lazy var artworkScript: NSAppleScript? = compile("""
    tell application id "com.apple.Music"
        if player state is stopped then return missing value
        set theTrack to current track
        if (count of artworks of theTrack) is 0 then return missing value
        return raw data of artwork 1 of theTrack
    end tell
    """)

    private func compile(_ source: String) -> NSAppleScript? {
        NSAppleScript(source: source)
    }

    /// True when Music.app is already launched. Checked first so that merely
    /// running this app never boots Music behind the user's back.
    var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    // MARK: - Reading

    func fetchSnapshot(_ completion: @escaping (Snapshot) -> Void) {
        guard isMusicRunning else {
            DispatchQueue.main.async { completion(Snapshot(state: .notRunning)) }
            return
        }
        queue.async {
            let snapshot = self.readSnapshot()
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    /// Blocking variant used by the `--dump-state` development flag.
    func snapshotSynchronously() -> Snapshot {
        guard isMusicRunning else { return Snapshot(state: .notRunning) }
        return queue.sync { readSnapshot() }
    }

    private func readSnapshot() -> Snapshot {
        var error: NSDictionary?
        guard let result = snapshotScript?.executeAndReturnError(&error), error == nil else {
            return Snapshot(state: .notRunning)
        }
        guard result.numberOfItems >= 7 else { return Snapshot(state: .stopped) }

        func string(_ index: Int) -> String { result.atIndex(index)?.stringValue ?? "" }
        func number(_ index: Int) -> Double { result.atIndex(index)?.doubleValue ?? 0 }

        let state: PlayerState
        switch string(1) {
        case "playing", "fast forwarding", "rewinding": state = .playing
        case "paused": state = .paused
        default: state = .stopped
        }

        if state == .stopped { return Snapshot(state: .stopped) }

        var track = Track()
        track.title = string(2)
        track.artist = string(3)
        track.album = string(4)
        track.duration = number(5)
        track.position = number(6)
        track.id = string(7)
        if track.id.isEmpty { track.id = "\(track.title)|\(track.artist)|\(track.album)" }

        return Snapshot(state: state, track: track)
    }

    func fetchArtwork(_ completion: @escaping (NSImage?) -> Void) {
        guard isMusicRunning else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        queue.async {
            var error: NSDictionary?
            let result = self.artworkScript?.executeAndReturnError(&error)
            var image: NSImage?
            if error == nil, let data = result?.data, !data.isEmpty {
                image = NSImage(data: data)
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    // MARK: - Transport

    private func perform(_ command: String) {
        guard isMusicRunning else { return }
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application id \"com.apple.Music\" to \(command)")?
                .executeAndReturnError(&error)
        }
    }

    func playPause() { perform("playpause") }
    func nextTrack() { perform("next track") }
    func previousTrack() { perform("back track") }

    func activateMusic() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        app.activate(options: [])
    }
}
