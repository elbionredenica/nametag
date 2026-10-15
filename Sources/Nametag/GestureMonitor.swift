import AppKit
import os

private let log = Logger(subsystem: "io.github.elbionredenica.nametag", category: "gestures")

/// Follows the trackpad's three/four-finger "dock swipe" — the gesture that opens and closes Mission
/// Control and switches desktops.
///
/// Mission Control reports nothing while your fingers move: it says it's open the instant a swipe-up
/// begins, and drops its Accessibility tree the instant a swipe-down begins. These events carry the
/// swipe's live progress instead. They're read through a session event tap (covered by the
/// Accessibility permission) on a background thread, so a busy main thread can never hold up the
/// system's gestures. Events always pass through untouched. (A listen-only tap would need the separate
/// Input Monitoring permission; an active tap that changes nothing only needs Accessibility.)
final class GestureMonitor {
    struct Swipe {
        /// Changes with every new swipe.
        let id: Int
        let vertical: Bool
        /// Negative while swiping up (opening), positive while swiping down; about ±1 at full travel.
        let progress: Double
    }

    private let lock = NSLock()
    private var active: Swipe?
    private var lastEnded = Date.distantPast
    private var lastWasHorizontal = false
    private var nextID = 0
    private var tap: CFMachPort?

    /// Called on the gesture thread when a vertical swipe (opening or closing Mission Control) begins.
    var onVerticalSwipeBegan: (() -> Void)?

    /// The swipe in progress, if any.
    var current: Swipe? {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// A sideways swipe (switching desktops) is in progress or just finished, while Mission
    /// Control's own positions are unreliable.
    var horizontalSettling: Bool {
        lock.lock(); defer { lock.unlock() }
        if let active { return !active.vertical }
        return lastWasHorizontal && Date().timeIntervalSince(lastEnded) < 0.4
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "Nametag gestures"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func run() {
        // Until Accessibility access is granted the tap can't be created; keep trying.
        while tap == nil {
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: (CGEventMask(1) << 29) | (CGEventMask(1) << 30),
                callback: gestureCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
            if tap == nil { Thread.sleep(forTimeInterval: 2) }
        }
        log.notice("gesture tap ready, input monitoring access: \(CGPreflightListenEventAccess())")
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap!, enable: true)
        CFRunLoopRun()
    }

    // Private CGEvent fields of a dock-swipe event (type 30), as observed on macOS 27.
    private static let hidType = CGEventField(rawValue: 110)!   // 23 = dock swipe
    private static let motion = CGEventField(rawValue: 123)!    // 1 = horizontal, 2 = vertical
    private static let progress = CGEventField(rawValue: 124)!
    private static let phase = CGEventField(rawValue: 132)!     // 1 began, 2 changed, 4 ended, 8 cancelled

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type.rawValue == 30, event.getIntegerValueField(Self.hidType) == 23 else { return }
        let phase = event.getIntegerValueField(Self.phase)
        let vertical = event.getIntegerValueField(Self.motion) == 2
        let progress = event.getDoubleValueField(Self.progress)

        lock.lock(); defer { lock.unlock() }
        switch phase {
        case 1:
            nextID += 1
            active = Swipe(id: nextID, vertical: vertical, progress: progress)
            if vertical { onVerticalSwipeBegan?() }
        case 2:
            if active == nil { nextID += 1 }
            active = Swipe(id: active?.id ?? nextID, vertical: active?.vertical ?? vertical, progress: progress)
        default:
            lastWasHorizontal = active.map { !$0.vertical } ?? !vertical
            active = nil
            lastEnded = Date()
        }
    }
}

private func gestureCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        Unmanaged<GestureMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}
