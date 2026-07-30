import AppKit
import Combine
import SwiftUI

/// Owns the current playback state and the record's rotation angle.
@MainActor
final class NowPlayingModel: ObservableObject {
    @Published private(set) var state: PlayerState = .notRunning
    @Published private(set) var track = Track()
    @Published private(set) var artwork: NSImage?

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
    /// Whether to fall back to an online cover lookup when Music has no local
    /// artwork. Turning this off keeps the app entirely offline.
    @Published var onlineArtwork: Bool = Defaults.bool("onlineArtwork", true) {
        didSet { Defaults.set(onlineArtwork, "onlineArtwork") }
    }

    private var timer: Timer?
    private var artworkTrackID: String?
    private var artworkAttempts = 0

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
        MusicBridge.shared.fetchSnapshot { [weak self] snapshot in
            guard let self else { return }
            self.apply(snapshot)
        }
    }

    private func apply(_ snapshot: Snapshot) {
        let wasPlaying = state.isPlaying
        let previousID = track.id

        state = snapshot.state
        track = snapshot.track

        if wasPlaying != state.isPlaying {
            setSpinning(state.isPlaying)
            // Poll less often while nothing is moving.
            scheduleTimer(interval: state.isPlaying ? 1.0 : 2.5)
        }

        if track.id != previousID {
            artwork = nil
            artworkTrackID = nil
            artworkAttempts = 0
            if !track.id.isEmpty { loadArtwork(for: track.id) }
        }
    }

    /// Music reports `count of artworks = 0` for a while on streaming tracks —
    /// the art is filled in only once it has been fetched. Retry a few times
    /// before settling for the printed-label fallback.
    private static let maxArtworkAttempts = 6
    private static let artworkRetryDelay: TimeInterval = 2

    private func loadArtwork(for id: String) {
        artworkAttempts += 1
        // Local first — library tracks never cause a network request.
        MusicBridge.shared.fetchArtwork { [weak self] image in
            guard let self, self.track.id == id else { return }
            if let image {
                self.artwork = image
                self.artworkTrackID = id
            } else if self.onlineArtwork {
                self.lookUpArtworkOnline(for: id)
            } else {
                self.scheduleArtworkRetry(for: id)
            }
        }
    }

    private func lookUpArtworkOnline(for id: String) {
        CatalogArtwork.shared.fetchArtwork(for: track) { [weak self] image in
            guard let self, self.track.id == id else { return }
            if let image {
                self.artwork = image
                self.artworkTrackID = id
            } else {
                self.scheduleArtworkRetry(for: id)
            }
        }
    }

    private func scheduleArtworkRetry(for id: String) {
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

    func angle(at date: Date) -> Double {
        guard let start = spinStart else { return spinBaseAngle }
        return spinBaseAngle + date.timeIntervalSince(start) * degreesPerSecond
    }

    /// 0...1 through the current track, used to place the tonearm.
    var progress: Double {
        guard track.duration > 0 else { return 0 }
        return min(max(track.position / track.duration, 0), 1)
    }

    // MARK: - Transport

    func playPause() {
        MusicBridge.shared.playPause()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refresh() }
    }

    func next() {
        MusicBridge.shared.nextTrack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.refresh() }
    }

    func previous() {
        MusicBridge.shared.previousTrack()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.refresh() }
    }
}
