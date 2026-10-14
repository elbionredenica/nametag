import AppKit

/// Where the desktop thumbnails really are while Mission Control's spaces bar is expanded.
///
/// Each thumbnail (with its "Desktop N" label underneath) is its own WindowManager window. The
/// window list's positions trail what's on screen by up to ~0.4s while the bar animates, but once
/// they stop changing they're the ground truth — Accessibility frames, which jump straight to an
/// animation's destination, occasionally disagree with them after the bar settles.
/// They also keep reporting while a close gesture drags the bar up, after Accessibility has gone quiet.
/// None of this needs Screen Recording permission: only owner names, layers and bounds are read.
final class ThumbnailTracker {
    private var ids: [CGWindowID] = []
    private var barCount = 0
    private var lastDiscovery = Date.distantPast
    private var lastFrames: [CGRect] = []
    private var lastMoved = Date.distantPast
    /// Vertical speed of the thumbnails in points per second, from the last two changes.
    private(set) var verticalSpeed: CGFloat = 0

    /// True once the thumbnails have stopped moving for a few frames.
    var isSettled: Bool { Date().timeIntervalSince(lastMoved) > 0.08 }

    /// Thumbnail frames in global top-left coordinates, sorted left to right.
    func frames() -> [CGRect] {
        // Look for new thumbnails often enough to catch the start of the expand animation.
        if Date().timeIntervalSince(lastDiscovery) > (ids.isEmpty ? 1.0 / 30 : 0.1) { discover() }
        guard !ids.isEmpty else { lastFrames = []; return [] }

        // Re-reading just the known windows is much cheaper than listing every window on screen.
        var pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let wanted = CFArrayCreate(nil, &pointers, pointers.count, nil),
              let info = CGWindowListCreateDescriptionFromArray(wanted) as? [[String: Any]]
        else { return [] }
        if info.count != ids.count { discover() }
        let frames = info.compactMap(bounds).filter { $0.width > 0 }.sorted { $0.minX < $1.minX }
        if frames != lastFrames {
            if let old = lastFrames.first, let new = frames.first, frames.count == lastFrames.count {
                let dt = max(Date().timeIntervalSince(lastMoved), 1.0 / 120)
                verticalSpeed = abs(new.minY - old.minY) / dt
            }
            lastFrames = frames
            lastMoved = Date()
        } else if isSettled {
            verticalSpeed = 0
        }
        return frames
    }

    /// Whether Mission Control's spaces bar is still on screen. It stays up for the whole of a close
    /// gesture (and comes back if the gesture is cancelled), unlike Mission Control's Accessibility tree.
    func barOnScreen() -> Bool {
        discover()
        return barCount > 0
    }

    func reset() {
        ids = []
        lastDiscovery = .distantPast
        lastFrames = []
        lastMoved = .distantPast
        verticalSpeed = 0
    }

    private func discover() {
        lastDiscovery = Date()
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { $0[kCGWindowOwnerName as String] as? String == "WindowManager" }

        // The spaces bar spans a display's full width at its top edge; thumbnails sit one layer above it.
        let displays = activeDisplayBounds()
        let bars = windows.compactMap { window -> Int? in
            guard let b = bounds(window), b.height < 400,
                  displays.contains(where: { $0.minX == b.minX && $0.minY == b.minY && $0.width == b.width })
            else { return nil }
            return window[kCGWindowLayer as String] as? Int
        }
        barCount = bars.count
        let barLayers = Set(bars)
        ids = windows.compactMap { window in
            guard let layer = window[kCGWindowLayer as String] as? Int, barLayers.contains(layer - 1),
                  let b = bounds(window), b.width < 400, b.height < 400,
                  let number = window[kCGWindowNumber as String] as? NSNumber
            else { return nil }
            return number.uint32Value
        }
    }

    private func bounds(_ window: [String: Any]) -> CGRect? {
        guard let dict = window[kCGWindowBounds as String] else { return nil }
        return CGRect(dictionaryRepresentation: dict as! CFDictionary)
    }

    private func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays.map(CGDisplayBounds)
    }
}
