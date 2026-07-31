import AppKit
import Combine
import SwiftUI

/// Owns the current playback state and the record's rotation angle.
@MainActor
final class NowPlayingModel: ObservableObject {
    @Published private(set) var state: PlayerState = .notRunning
    @Published private(set) var track = Track()
    @Published private(set) var artwork: NSImage?
    /// The cover being faded out from. Kept alongside the current one so the
    /// two can be blended rather than swapped.
    @Published private(set) var previousArtwork: NSImage?
    /// When the current cover took over, which the fade is derived from.
    @Published private(set) var artworkChangedAt = Date.distantPast

    /// Long and gentle: the change should register as the label settling, not
    /// as a cut.
    static let artworkFadeDuration: TimeInterval = 1.1

    /// Revolutions per minute of the turntable.
    @Published var rpm: Double = Defaults.double("rpm", 33.3333) {
        didSet {
            Defaults.set(rpm, "rpm")
            restampSpin()
        }
    }
    @Published var alwaysOnTop: Bool = Defaults.bool("alwaysOnTop", true) {
        didSet { Defaults.set(alwaysOnTop, "alwaysOnTop") }
    }
    @Published var showTrackInfo: Bool = Defaults.bool("showTrackInfo", true) {
        didSet { Defaults.set(showTrackInfo, "showTrackInfo") }
    }
    /// Draw the animated colour field behind the record instead of leaving the
    /// window transparent.
    @Published var glassBackground: Bool = Defaults.bool("glassBackground", false) {
        didSet { Defaults.set(glassBackground, "glassBackground") }
    }
    /// How the record is drawn — classic vinyl, picture disc, or clear.
    @Published var discStyle: DiscStyle =
        DiscStyle(rawValue: Defaults.string("discStyle", DiscStyle.classic.rawValue)) ?? .classic {
        didSet { Defaults.set(discStyle.rawValue, "discStyle") }
    }
    /// Representative colours of the current cover, tinting that background.
    @Published private(set) var palette: [Color] = []

    /// Whether to fall back to an online cover lookup when Music has no local
    /// artwork. Turning this off keeps the app entirely offline.
    @Published var onlineArtwork: Bool = Defaults.bool("onlineArtwork", true) {
        didSet { Defaults.set(onlineArtwork, "onlineArtwork") }
    }

    /// Route the keyboard's ⏮ / ⏭ keys through the app so they can drive the
    /// queue. Needs Accessibility, so it is opt-in.
    @Published var interceptMediaKeys: Bool = Defaults.bool("interceptMediaKeys", true) {
        didSet {
            Defaults.set(interceptMediaKeys, "interceptMediaKeys")
            syncMediaKeyTap()
        }
    }

    /// Set while playback is being driven from the playlist browser.
    @Published private(set) var queue: Queue?

    /// True while the user is holding the record.
    @Published private(set) var isScrubbing = false
    /// Rotation contributed by dragging, on top of the free-running spin.
    @Published private(set) var manualOffset: Double = 0

    private var timer: Timer?
    private var lastPermissionCheck = Date.distantPast
    private var artworkTrackID: String?
    private var artworkAttempts = 0

    /// Transport commands issued but not yet acknowledged by Music.
    private var pendingCommands = 0

    /// The state a just-issued command should produce. Music's `player state`
    /// lags the command that caused it — measured at up to ~450ms — so an
    /// acknowledgement is not proof the state has flipped yet. Snapshots that
    /// disagree are ignored until one confirms, or until the deadline passes
    /// and reality wins (in case the command simply didn't take).
    private var expectedState: PlayerState?
    private var expectationDeadline = Date.distantPast
    private static let expectationTimeout: TimeInterval = 1.5
    private var resumeAfterScrub = false
    private var scrubStartPosition: Double = 0
    private var scrubDegrees: Double = 0
    private var seekInFlight = false
    private var pendingSeek: Double?

    // Rotation is derived from wall-clock time rather than accumulated per
    // frame, so it stays smooth and survives dropped frames. Pausing freezes
    // the angle by folding elapsed rotation back into `spinBaseAngle`.
    private var spinBaseAngle: Double = 0
    private var spinStart: Date?

    init() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(musicNotification),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
        refresh()
        scheduleTimer(interval: 1.0)

        MediaKeyTap.shared.onNext = { [weak self] in self?.next() }
        MediaKeyTap.shared.onPrevious = { [weak self] in self?.previous() }
        // Only take the keys when Music itself could not act on them; the rest
        // of the time they belong to Music.
        MediaKeyTap.shared.shouldIntercept = { [weak self] in self?.queue != nil }
        // Ask up front when the feature is on: without Accessibility the keys
        // silently do nothing, which is indistinguishable from a bug.
        syncMediaKeyTap(promptIfNeeded: true)
    }

    /// Starts or stops the key tap to match the setting, prompting for
    /// Accessibility the first time it is switched on.
    func syncMediaKeyTap(promptIfNeeded: Bool = false) {
        guard interceptMediaKeys else {
            MediaKeyTap.shared.stop()
            return
        }
        if promptIfNeeded && !MediaKeyTap.shared.hasAccessibilityPermission {
            MediaKeyTap.shared.requestPermission()
        }
        MediaKeyTap.shared.start()
    }

    /// True when the keys are wanted but macOS has not granted access yet.
    var mediaKeysNeedPermission: Bool {
        interceptMediaKeys && !MediaKeyTap.shared.hasAccessibilityPermission
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private nonisolated func musicNotification(_ note: Notification) {
        Task { @MainActor in self.refresh() }
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        // While scrubbing, every seek makes Music post a playerInfo
        // notification, and each of those would queue a snapshot read on the
        // same serial queue the seeks use — measured at ~700ms of backlog,
        // which the user feels as the record lagging their hand. The polls
        // would be discarded anyway, so don't issue them.
        guard !isScrubbing else { return }
        // Accessibility may be granted while the app is already running; pick
        // it up rather than making the user relaunch. Checked occasionally
        // rather than on every poll — it is a call into the TCC daemon.
        if interceptMediaKeys, !MediaKeyTap.shared.isRunning,
           Date().timeIntervalSince(lastPermissionCheck) > 10 {
            lastPermissionCheck = Date()
            syncMediaKeyTap()
        }
        MusicBridge.shared.fetchSnapshot { [weak self] snapshot in
            guard let self else { return }
            self.apply(snapshot)
        }
    }

    private func apply(_ snapshot: Snapshot) {
        // Don't let a stale poll fight an optimistic transport update, and
        // don't let position polling stutter the record mid-drag.
        var blocked = pendingCommands > 0 || isScrubbing
        if !blocked, let expected = expectedState {
            if snapshot.state == expected {
                expectedState = nil
            } else if Date() < expectationDeadline {
                blocked = true
            } else {
                expectedState = nil
            }
        }
        Trace.log("apply(\(snapshot.state.rawValue)) blocked=\(blocked) state=\(state.rawValue) expect=\(expectedState?.rawValue ?? "-")")
        guard !blocked else { return }

        let wasPlaying = state.isPlaying
        let previousID = track.id

        state = snapshot.state
        track = snapshot.track

        // Deliberately no auto-advance here. Carrying the queue forward on a
        // stopped snapshot was tried and ran away: Music reports `stopped`
        // briefly *during* a track switch too, which is indistinguishable from
        // reaching the end, so each advance triggered the next and the queue
        // galloped from track 3 to 9 on its own. Ending a track picked from the
        // browser therefore stops rather than continuing the list.

        if wasPlaying != state.isPlaying {
            setSpinning(state.isPlaying)
            // Poll less often while nothing is moving.
            scheduleTimer(interval: state.isPlaying ? 1.0 : 2.5)
        }

        if track.id != previousID {
            // Deliberately *not* cleared here. Blanking the label the moment the
            // track changes puts the printed fallback on screen for however long
            // the lookup takes — up to a second on a streaming track — which
            // reads as a flicker. The previous cover stays until the new one
            // resolves, or until every source has failed (see scheduleArtworkRetry).
            artworkTrackID = nil
            artworkAttempts = 0
            if track.id.isEmpty {
                setArtwork(nil, for: nil)
            } else {
                loadArtwork(for: track.id)
            }
        }
    }

    /// Music reports `count of artworks = 0` for a while on streaming tracks —
    /// the art is filled in only once it has been fetched. Retry a few times
    /// before settling for the printed-label fallback.
    private static let maxArtworkAttempts = 6
    private static let artworkRetryDelay: TimeInterval = 2

    private func loadArtwork(for id: String) {
        artworkAttempts += 1
        // Library tracks: Music's own artwork is authoritative, and asking it
        // costs no network. Streaming tracks: Music's artwork has been observed
        // returning a stale cover from a different release entirely, so prefer
        // the catalogue, which is checked against the track's own title.
        if track.isStreaming && onlineArtwork {
            lookUpArtworkOnline(for: id, thenFallBackToMusic: true)
        } else {
            loadArtworkFromMusic(for: id)
        }
    }

    private func loadArtworkFromMusic(for id: String, allowOnline: Bool = true) {
        MusicBridge.shared.fetchArtwork { [weak self] image in
            guard let self, self.track.id == id else { return }
            if let image {
                self.setArtwork(image, for: id)
            } else if allowOnline && self.onlineArtwork {
                self.lookUpArtworkOnline(for: id, thenFallBackToMusic: false)
            } else {
                self.scheduleArtworkRetry(for: id)
            }
        }
    }

    private func lookUpArtworkOnline(for id: String, thenFallBackToMusic: Bool) {
        CatalogArtwork.shared.fetchArtwork(for: track) { [weak self] image in
            guard let self, self.track.id == id else { return }
            if let image {
                self.setArtwork(image, for: id)
            } else if thenFallBackToMusic {
                // No confident catalogue match: a possibly-stale cover from
                // Music still beats no cover at all.
                self.loadArtworkFromMusic(for: id, allowOnline: false)
            } else {
                self.scheduleArtworkRetry(for: id)
            }
        }
    }

    /// Stores the cover and derives its palette off the main thread — the
    /// extraction walks a downsampled bitmap and would otherwise hitch the spin.
    private func setArtwork(_ image: NSImage?, for id: String?) {
        if image !== artwork {
            previousArtwork = artwork
            artworkChangedAt = Date()
        }
        artwork = image
        artworkTrackID = id
        guard let image else {
            palette = []
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let colors = Palette.extract(from: image)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.artworkTrackID == id else { return }
                self.palette = colors
            }
        }
    }

    private func scheduleArtworkRetry(for id: String) {
        // Every source has now come back empty for this track, so the cover
        // still on screen belongs to the previous one. Let it go.
        if artwork != nil && artworkTrackID == nil { setArtwork(nil, for: nil) }
        guard artworkAttempts < Self.maxArtworkAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.artworkRetryDelay) { [weak self] in
            guard let self, self.track.id == id, self.artwork == nil else { return }
            self.loadArtwork(for: id)
        }
    }

    // MARK: - Rotation

    private func setSpinning(_ spinning: Bool) {
        if spinning {
            guard spinStart == nil else { return }
            spinStart = Date()
        } else {
            spinBaseAngle = angle(at: Date())
            spinStart = nil
        }
    }

    /// Re-anchor the spin so a speed change doesn't make the label jump.
    private func restampSpin() {
        guard spinStart != nil else { return }
        spinBaseAngle = angle(at: Date())
        spinStart = Date()
    }

    private var degreesPerSecond: Double { rpm * 360.0 / 60.0 }

    /// Redraw often enough to keep the angular step per frame constant —
    /// roughly 3.3°, which is what 33⅓ RPM at 60fps gives — and no more.
    var frameInterval: Double {
        guard degreesPerSecond > 0 else { return 1.0 / 30.0 }
        return min(max(3.3 / degreesPerSecond, 1.0 / 60.0), 1.0 / 24.0)
    }

    func angle(at date: Date) -> Double {
        guard let start = spinStart else { return spinBaseAngle + manualOffset }
        return spinBaseAngle + date.timeIntervalSince(start) * degreesPerSecond + manualOffset
    }

    /// Seconds of audio per full revolution — 1.8 s at 33⅓ RPM, exactly as on a
    /// real turntable, so a half turn of the record scrubs half a rotation's
    /// worth of the song.
    private var secondsPerRevolution: Double { 60.0 / rpm }

    // MARK: - Direct manipulation

    /// Lifts the needle off the record (stopping playback) or drops it back on.
    /// The arm's position is just a view of playback state — see
    /// `ContentView.armEngaged` — so pausing from anywhere lifts it.
    func toggleArm() {
        issue(state.isPlaying ? .pause : .play, optimistic: state.isPlaying ? .paused : .playing)
    }

    /// The user has grabbed the record; stop playback the way a hand on a
    /// spinning disc would.
    func beginScrub() {
        guard state == .playing || state == .paused else { return }
        isScrubbing = true
        resumeAfterScrub = state.isPlaying
        scrubStartPosition = track.position
        scrubDegrees = 0
        if state.isPlaying { issue(.pause, optimistic: .paused) }
    }

    /// Rotate the record by hand, dragging the playback position with it.
    func updateScrub(deltaDegrees: Double) {
        guard isScrubbing else { return }
        manualOffset += deltaDegrees
        scrubDegrees += deltaDegrees

        guard track.duration > 0 else { return }
        let target = scrubStartPosition + (scrubDegrees / 360.0) * secondsPerRevolution
        requestSeek(min(max(target, 0), max(track.duration - 0.1, 0)))
    }

    /// Let go: playback resumes from wherever the record was left.
    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        if resumeAfterScrub { issue(.play, optimistic: .playing) }
        // Fold the hand-rotation into the spin so the label doesn't jump.
        spinBaseAngle += manualOffset
        manualOffset = 0
        if spinStart != nil { spinStart = Date() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    /// Coalescing seek: keeps one request in flight and always sends the most
    /// recent target, so fast dragging never backs up behind stale positions.
    private func requestSeek(_ seconds: Double) {
        pendingSeek = seconds
        track.position = seconds
        flushSeek()
    }

    private func flushSeek() {
        guard !seekInFlight, let target = pendingSeek else { return }
        pendingSeek = nil
        seekInFlight = true
        Trace.log(String(format: "seek -> %.2f", target))
        MusicBridge.shared.seek(to: target) { [weak self] in
            guard let self else { return }
            Trace.log("seek done")
            self.seekInFlight = false
            self.flushSeek()
        }
    }

    /// Where playback came from when the user picked a track out of a
    /// playlist. Music forgets the playlist in that case, so this is what
    /// makes next and previous work afterwards.
    struct Queue {
        var playlistID: String
        var index: Int
        var count: Int
    }

    private enum Transport {
        case play, pause, playPause, next, previous
        case queued(playlistID: String, index: Int)
    }

    /// Sends a transport command, shows its effect immediately, and ignores
    /// polling until Music confirms — then re-reads the truth.
    private func issue(_ transport: Transport, optimistic: PlayerState?) {
        Trace.log("issue(\(transport)) optimistic=\(optimistic?.rawValue ?? "-")")
        pendingCommands += 1
        if let optimistic {
            state = optimistic
            setSpinning(optimistic.isPlaying)
            expectedState = optimistic
            expectationDeadline = Date().addingTimeInterval(Self.expectationTimeout)
        }
        let acknowledged: () -> Void = { [weak self] in
            guard let self else { return }
            self.pendingCommands -= 1
            guard self.pendingCommands == 0 else { return }
            self.refresh()
            // Music's state can take a moment to catch up; look again shortly so
            // the expectation resolves without waiting for the next poll tick.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.refresh() }
        }
        switch transport {
        case .play: MusicBridge.shared.play(completion: acknowledged)
        case .pause: MusicBridge.shared.pause(completion: acknowledged)
        case .playPause: MusicBridge.shared.playPause(completion: acknowledged)
        case .next: MusicBridge.shared.nextTrack(completion: acknowledged)
        case .previous: MusicBridge.shared.previousTrack(completion: acknowledged)
        case let .queued(playlistID, index):
            MusicBridge.shared.playTrack(at: index, inPlaylistWithID: playlistID, completion: acknowledged)
        }
    }

    /// How far the cover cross-fade has progressed, eased. Derived from the
    /// clock rather than a SwiftUI animation: the label lives inside a
    /// TimelineView that rebuilds every frame, which disrupts transitions.
    func artworkFade(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(artworkChangedAt)
        guard elapsed < Self.artworkFadeDuration else { return 1 }
        let t = max(0, elapsed / Self.artworkFadeDuration)
        // Smoothstep, so it eases in and out instead of ramping linearly.
        return t * t * (3 - 2 * t)
    }

    /// True while a cover change is still blending, so the view keeps drawing
    /// even when the record itself is stopped.
    var isCrossFadingArtwork: Bool {
        Date().timeIntervalSince(artworkChangedAt) < Self.artworkFadeDuration
    }

    /// 0...1 through the current track, used to place the tonearm.
    var progress: Double {
        guard track.duration > 0 else { return 0 }
        return min(max(track.position / track.duration, 0), 1)
    }

    // MARK: - Transport

    func playPause() {
        issue(.playPause, optimistic: state.isPlaying ? .paused : .playing)
    }

    /// Plays a whole playlist, which gives Music a context it can advance
    /// through on its own — so the stand-in queue is dropped.
    func playPlaylist(id: String) {
        queue = nil
        MusicBridge.shared.playPlaylist(id: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    /// Starts a track from the playlist browser and remembers where it came
    /// from, so the rest of the list stays reachable.
    ///
    /// Note the queue is *not* dropped when Music reports a current playlist:
    /// after picking a lone track it names one (e.g. "Music Videos") while
    /// still refusing to advance, so its having a playlist proves nothing.
    func playFromQueue(playlistID: String, index: Int, count: Int) {
        queue = Queue(playlistID: playlistID, index: index, count: count)
        issue(.queued(playlistID: playlistID, index: index), optimistic: .playing)
    }

    func next() {
        // Music's own next track is a no-op when it has no current playlist,
        // which is exactly the state picking a track out of one leaves it in.
        if let queue, queue.index < queue.count {
            playFromQueue(playlistID: queue.playlistID, index: queue.index + 1, count: queue.count)
        } else {
            issue(.next, optimistic: nil)
        }
    }

    func previous() {
        if let queue, queue.index > 1 {
            playFromQueue(playlistID: queue.playlistID, index: queue.index - 1, count: queue.count)
        } else {
            issue(.previous, optimistic: nil)
        }
    }
}
