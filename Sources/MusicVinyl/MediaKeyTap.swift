import AppKit
import Foundation

/// Catches the keyboard's ⏮ / ⏭ keys before Music sees them.
///
/// Needed because those keys talk to Music directly, and Music cannot advance
/// through a track that was played on its own — the very case the app's queue
/// exists to cover. The tap only swallows a key when the queue is active;
/// otherwise the event passes straight through and Music behaves normally.
///
/// This requires Accessibility permission, which is why it is a setting rather
/// than something the app just does.
@MainActor
final class MediaKeyTap {
    static let shared = MediaKeyTap()

    /// Called on the main actor when a key is intercepted.
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    /// Consulted per keypress: when false the event is passed on untouched.
    var shouldIntercept: () -> Bool = { false }

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Media keys arrive as NSSystemDefined events with subtype 8; the key
    /// itself is packed into the high half of `data1`.
    private static let systemDefinedSubtype: Int16 = 8
    /// CGEventType has no case for it, but NSSystemDefined is event type 14.
    private static let systemDefinedType = UInt32(NSEvent.EventType.systemDefined.rawValue)
    private static let keyPlay = 16
    private static let keyNext = 17
    private static let keyPrevious = 18
    private static let keyFastForward = 19
    private static let keyRewind = 20

    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Asks for Accessibility if it isn't granted yet. macOS shows its own
    /// prompt; there is no way to grant it from inside the app.
    @discardableResult
    func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard AXIsProcessTrusted() else { return false }

        let mask = CGEventMask(1 << Self.systemDefinedType)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated { tap.handle(type: type, event: event) }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        isRunning = true
        return true
    }

    func stop() {
        guard let tap, let source else {
            isRunning = false
            return
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
        isRunning = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long; re-arming it is the
        // documented recovery, and without this the keys quietly stop working.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == Self.systemDefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.systemDefinedSubtype,
              shouldIntercept()
        else { return Unmanaged.passUnretained(event) }

        let data = nsEvent.data1
        let keyCode = Int((data & 0xFFFF_0000) >> 16)
        let isKeyDown = ((data & 0x0000_FF00) >> 8) == 0x0A

        switch keyCode {
        case Self.keyNext, Self.keyFastForward:
            if isKeyDown { onNext?() }
            return nil          // swallowed: Music would do nothing with it
        case Self.keyPrevious, Self.keyRewind:
            if isKeyDown { onPrevious?() }
            return nil
        default:
            // Play/pause is deliberately left alone — Music handles it fine.
            return Unmanaged.passUnretained(event)
        }
    }
}
