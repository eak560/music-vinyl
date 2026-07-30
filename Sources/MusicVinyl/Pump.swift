import Foundation

/// Run-loop pumping for the command-line development flags, which have no
/// NSApplication to drive the main queue for them.
///
/// These flags must never block the main thread waiting on the AppleScript
/// queue: `NSAppleScript` needs the main run loop to deliver its Apple Event
/// reply, so a `queue.sync` from the main thread deadlocks. Pumping keeps the
/// main thread live while the work completes.
enum Pump {
    /// Services the main run loop for a fixed stretch.
    static func drain(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(min(0.05, remaining)))
        }
    }

    /// Pumps until `condition` holds or the timeout elapses. Returns whether the
    /// condition was met.
    @discardableResult
    static func wait(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            drain(0.01)
        }
        return true
    }
}
