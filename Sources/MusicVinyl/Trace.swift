import Foundation

/// Opt-in state tracing for the development flags. Set `VINYL_TRACE=1` to see
/// how playback state transitions interleave with polling.
enum Trace {
    static let enabled = ProcessInfo.processInfo.environment["VINYL_TRACE"] != nil
    private static let start = Date()

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print(String(format: "    t=%6.3f  %@", Date().timeIntervalSince(start), message()))
    }
}
