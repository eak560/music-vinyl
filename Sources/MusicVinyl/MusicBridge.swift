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
    /// Apple Music streaming track (`class of current track` is `URL track`)
    /// rather than something in the library. Music's own artwork for these is
    /// unreliable — it reports none at all for some, and a stale cover from a
    /// different release for others — so they are treated differently.
    var isStreaming = false
    /// Name of the playlist being played from, when there is one.
    var playlist: String = ""

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
        if theState is "stopped" then return {theState, "", "", "", 0, 0, "", "", ""}
        set theTrack to current track
        set theList to ""
        try
            set theList to (name of current playlist as text)
        end try
        return {theState, (name of theTrack as text), (artist of theTrack as text), ¬
                (album of theTrack as text), (duration of theTrack), (player position), ¬
                (persistent ID of theTrack as text), (class of theTrack as text), theList}
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

    // Deliberately no synchronous snapshot API: blocking the main thread on
    // this queue deadlocks, because the AppleScript running on it needs the
    // main run loop to deliver its Apple Event reply. Callers that need a
    // blocking read should pump the run loop instead — see `Pump`.

    private func readSnapshot() -> Snapshot {
        var error: NSDictionary?
        guard let result = snapshotScript?.executeAndReturnError(&error), error == nil else {
            return Snapshot(state: .notRunning)
        }
        guard result.numberOfItems >= 9 else { return Snapshot(state: .stopped) }

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
        track.isStreaming = string(8).localizedCaseInsensitiveContains("URL track")
        track.playlist = string(9)
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

    /// Runs a transport command, reporting back on the main queue once Music has
    /// processed it. Commands and snapshot reads share one serial queue, so a
    /// snapshot that was already queued behind an older state is guaranteed to
    /// be delivered *before* this completion — which is what lets the caller
    /// tell stale readings from fresh ones.
    /// Runs an arbitrary script on the AppleScript queue and hands the raw
    /// descriptor back on the main queue. Used by the playlist browser, which
    /// needs list results rather than a fixed snapshot shape.
    func runScript(_ source: String, completion: @escaping (NSAppleEventDescriptor?) -> Void) {
        guard isMusicRunning else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { Trace.log("runScript error: \(error)") }
            DispatchQueue.main.async { completion(error == nil ? result : nil) }
        }
    }

    func perform(_ command: String, completion: (() -> Void)? = nil) {
        guard isMusicRunning else {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application id \"com.apple.Music\" to \(command)")?
                .executeAndReturnError(&error)
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    func playPause(completion: (() -> Void)? = nil) { perform("playpause", completion: completion) }
    func nextTrack(completion: (() -> Void)? = nil) { perform("next track", completion: completion) }
    func previousTrack(completion: (() -> Void)? = nil) { perform("back track", completion: completion) }

    // Explicit play/pause rather than `playpause`, so the gesture handlers can
    // state what they want instead of toggling whatever Music happens to be in.
    func play(completion: (() -> Void)? = nil) { perform("play", completion: completion) }
    func pause(completion: (() -> Void)? = nil) { perform("pause", completion: completion) }

    /// Seeks, then reports back on the main queue. The completion lets the
    /// caller keep exactly one seek in flight while scrubbing, instead of
    /// piling requests onto the queue faster than Music can service them.
    func seek(to seconds: Double, completion: @escaping () -> Void) {
        guard isMusicRunning else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        queue.async {
            Trace.log(String(format: "bridge.seek enter %.2f", seconds))
            var error: NSDictionary?
            NSAppleScript(source: """
            tell application id "com.apple.Music" to set player position to \(seconds)
            """)?.executeAndReturnError(&error)
            Trace.log("bridge.seek done err=\(error?["NSAppleScriptErrorNumber"] ?? "none")")
            DispatchQueue.main.async(execute: completion)
        }
    }

    func activateMusic() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        app.activate(options: [])
    }
}
