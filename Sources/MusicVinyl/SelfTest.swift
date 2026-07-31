import AppKit
import Foundation

/// Development helper: `MusicVinyl --selftest` drives the gesture handlers
/// against a live Music.app and reports what actually happened, which is the
/// only way to exercise them without a mouse. It restores the playback state it
/// started with.
///
/// The test body runs on a background thread while the main thread runs a real
/// `NSApplication` loop. That matters: the model is main-actor bound and its
/// callbacks land on the main queue, so the checks need a genuinely live main
/// thread rather than hand-rolled run-loop pumping.
enum SelfTest {
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
        sleep(1.2)

        guard onMain({ model.state == .playing || model.state == .paused }) else {
            print("SKIP: Music must be playing or paused (state: \(onMain { model.state.rawValue }))")
            exit(1)
        }

        let originalPosition = onMain { model.track.position }
        let wasPlaying = onMain { model.state.isPlaying }
        print("start: state=\(onMain { model.state.rawValue }) pos=\(fmt(originalPosition))")

        // 1. Lifting the tonearm should stop playback.
        print("\n-- tonearm --")
        if !onMain({ model.state.isPlaying }) {
            onMain { model.playPause() }
            sleep(1.2)
        }
        onMain { model.toggleArm() }
        sleep(1.0)
        check("clicking arm stops music",
              onMain { !model.state.isPlaying } && live().state == .paused,
              "model=\(onMain { model.state.rawValue }) music=\(live().state.rawValue)")

        onMain { model.toggleArm() }
        sleep(1.4)
        check("clicking arm again resumes music",
              onMain { model.state.isPlaying } && live().state == .playing,
              "model=\(onMain { model.state.rawValue }) music=\(live().state.rawValue)")

        // Move well clear of the track's start before scrubbing: a scrub
        // reaching below zero is clamped, which reads as drift. This has to
        // happen before the record is grabbed, because beginScrub captures the
        // position it scrubs from.
        let safe = max(30, live().track.duration * 0.25)
        let seeked = DispatchSemaphore(value: 0)
        onMain { MusicBridge.shared.seek(to: safe) { seeked.signal() } }
        _ = seeked.wait(timeout: .now() + 5)
        sleep(1.0)

        // 2. Holding the record should stop it.
        print("\n-- holding the record --")
        // Read the origin in the same main-actor hop that captures it, so the
        // test and the model are scrubbing from the identical value.
        let base: Double = onMain {
            let origin = model.track.position
            model.beginScrub()
            return origin
        }
        sleep(0.7)
        check("grabbing stops music",
              onMain { model.isScrubbing && !model.state.isPlaying } && live().state == .paused,
              "scrubbing=\(onMain { model.isScrubbing }) music=\(live().state.rawValue)")

        // 3. Turning it should drag the playback position with it.
        //    Derived from the configured speed, not hardcoded: the scrub ratio
        //    follows the turntable, so at the 15.9 RPM this was once run at a
        //    half turn is 1.88s of audio rather than 33⅓'s 0.9s.
        //
        //    Move well clear of the track's start first: a scrub reaching below
        //    zero is clamped, which would be read as drift rather than as the
        //    intended behaviour.
        print("\n-- scrubbing --")
        let halfTurn = onMain { 30.0 / model.rpm }
        print(String(format: "  %.1f RPM — a half turn is %.2fs of audio",
                     onMain { model.rpm }, halfTurn))
        turn(model, degrees: 180, steps: 18)
        sleep(0.8)
        report("+180 deg", expected: base + halfTurn,
               model: onMain { model.track.position }, music: settledPosition())

        turn(model, degrees: -360, steps: 36)
        sleep(0.8)
        report("-360 deg", expected: base - halfTurn,
               model: onMain { model.track.position }, music: settledPosition())

        onMain { model.endScrub() }
        sleep(1.6)
        check("releasing resumes music",
              onMain { model.state.isPlaying } && live().state == .playing,
              "model=\(onMain { model.state.rawValue }) music=\(live().state.rawValue)")
        check("hand rotation folded into spin", onMain { model.manualOffset == 0 })

        // Put the user's playback back where it was.
        print("")
        let restored = DispatchSemaphore(value: 0)
        onMain { MusicBridge.shared.seek(to: originalPosition) { restored.signal() } }
        _ = restored.wait(timeout: .now() + 5)
        onMain { wasPlaying ? MusicBridge.shared.play() : MusicBridge.shared.pause() }
        sleep(0.8)
        let final = live()
        print("restored: state=\(final.state.rawValue) pos=\(fmt(final.track.position))")
        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    private static func turn(_ model: NowPlayingModel, degrees: Double, steps: Int) {
        for _ in 0..<steps {
            onMain { model.updateScrub(deltaDegrees: degrees / Double(steps)) }
            sleep(0.02)
        }
    }

    // MARK: - Plumbing

    /// Runs work on the main actor and waits for it. Safe to block here: this
    /// is a background thread, and the main thread is running the app loop.
    private static func onMain<T>(_ work: @MainActor @escaping () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated { work() } }
    }

    /// Music reports `player position` a beat behind a seek, so sample until it
    /// stops moving rather than trusting the first read.
    private static func settledPosition() -> Double {
        var previous = live().track.position
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            sleep(0.2)
            let current = live().track.position
            if abs(current - previous) < 0.02 { return current }
            previous = current
        }
        return previous
    }

    /// Music's real state, read through the normal async path.
    private static func live() -> Snapshot {
        var result = Snapshot(state: .notRunning)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MusicBridge.shared.fetchSnapshot { snapshot in
                result = snapshot
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 5)
        return result
    }

    private static func sleep(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private static func check(_ label: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
        if !passed { failures += 1 }
        let suffix = detail().isEmpty ? "" : "  [\(detail())]"
        print("\(passed ? "PASS" : "FAIL")  \(label)\(suffix)")
    }

    /// Two different things are checked here, because only one of them is ours.
    ///
    /// The model's own target must be exact — that is the scrub arithmetic.
    /// Where Music actually lands is reported but not failed: it accepts
    /// `set player position` without error and then does not honour it
    /// precisely on a long backwards seek into a stream. Observed at 15.9 RPM,
    /// where a full turn is 3.8s of audio: the final seek to 130.99s returned
    /// cleanly and Music settled at 133.40s. Short sweeps land exactly.
    private static let modelTolerance = 0.05
    private static let musicTolerance = 0.5

    private static func report(_ label: String, expected: Double, model: Double, music: Double) {
        let modelDrift = abs(model - expected)
        let musicDrift = abs(music - expected)
        if modelDrift > Self.modelTolerance { failures += 1 }
        let note = musicDrift > Self.musicTolerance
            ? String(format: "  (Music landed %.2fs away — its own seek accuracy)", musicDrift)
            : ""
        print(String(format: "%@  %@: expected %@  model %@  music %@%@",
                     modelDrift <= Self.modelTolerance ? "PASS" : "FAIL", label,
                     fmt(expected), fmt(model), fmt(music), note))
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.2fs", value) }
}
