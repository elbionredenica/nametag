import AppKit
import os

private let log = Logger(subsystem: "io.github.elbionredenica.nametag", category: "keys")

/// Takes the keyboard while a name is being edited inside Mission Control.
///
/// Mission Control swallows keystrokes even when another app's window has keyboard focus, so
/// rename-in-place reads them with a session event tap (covered by the Accessibility permission)
/// and keeps them from reaching anything else. The tap only exists while editing.
final class KeyCapture {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: ((NSEvent) -> Void)?

    var isActive: Bool { tap != nil }

    @discardableResult
    func start(_ handler: @escaping (NSEvent) -> Void) -> Bool {
        stop()
        self.handler = handler
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: keyCaptureCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.notice("rename keyboard capture started")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        handler = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            if let ns = NSEvent(cgEvent: event) {
                DispatchQueue.main.async { [weak self] in self?.handler?(ns) }
            }
            return nil
        case .keyUp:
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

private func keyCaptureCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<KeyCapture>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
}
