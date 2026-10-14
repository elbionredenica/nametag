import AppKit
import ApplicationServices

/// A "Desktop N" label in Mission Control's spaces bar, in global top-left screen coordinates.
struct MissionControlLabel {
    let title: String
    let center: CGPoint
    /// True when the bar is expanded into thumbnails (pointer hovering at the top).
    let expanded: Bool
    let selected: Bool
    let button: AXUIElement
}

struct MissionControlDisplay {
    let displayID: CGDirectDisplayID
    /// Global top-left coordinates.
    let frame: CGRect
    let labels: [MissionControlLabel]
}

/// Reads Mission Control's spaces bar through the Accessibility API.
///
/// Since macOS 26/27 Mission Control is drawn by the WindowManager process. While it is open,
/// WindowManager exposes `mc.display` > `mc.spaces` > `mc.spaces.list` > one button per desktop.
/// macOS posts no notification when Mission Control opens, so callers poll `isOpen()`.
/// These frames jump straight to where an animation ends; `ThumbnailTracker` has the live ones.
final class MissionControlReader {
    private var app: AXUIElement?
    private var pid: pid_t = 0

    func isOpen() -> Bool {
        guard let app = resolveApp() else { return false }
        return children(app).contains { identifier($0) == "mc.display" }
    }

    func read() -> [MissionControlDisplay] {
        guard let app = resolveApp() else { return [] }
        return children(app).filter { identifier($0) == "mc.display" }.compactMap { display in
            guard let number = attribute(display, "AXDisplayID") as? NSNumber,
                  let spaces = children(display).first(where: { identifier($0) == "mc.spaces" }),
                  let list = children(spaces).first(where: { identifier($0) == "mc.spaces.list" })
            else { return nil }

            let displayTop = frame(display).minY
            let selected = (attribute(list, kAXSelectedChildrenAttribute) as? [AXUIElement]) ?? []
            let labels = children(list).map { button -> MissionControlLabel in
                let f = frame(button)
                let expanded = f.minY - displayTop > 40
                // The button's frame origin x is the label's center. Its center y sits a fixed
                // distance below the frame's top (measured on macOS 27 against Apple's pill).
                return MissionControlLabel(
                    title: attribute(button, kAXTitleAttribute) as? String ?? "",
                    center: CGPoint(x: f.minX, y: f.minY + (expanded ? 53.5 : 52.25)),
                    expanded: expanded,
                    selected: selected.contains { CFEqual($0, button) },
                    button: button
                )
            }
            return MissionControlDisplay(displayID: number.uint32Value, frame: frame(display), labels: labels)
        }
    }

    /// Same as clicking the label: switches to that desktop and closes Mission Control.
    func press(_ label: MissionControlLabel) {
        AXUIElementPerformAction(label.button, kAXPressAction as CFString)
    }

    private func resolveApp() -> AXUIElement? {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first
        else { app = nil; return nil }
        if running.processIdentifier != pid || app == nil {
            pid = running.processIdentifier
            app = AXUIElementCreateApplication(pid)
        }
        return app
    }
}

// MARK: - AX helpers

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func identifier(_ element: AXUIElement) -> String? {
    attribute(element, kAXIdentifierAttribute) as? String
}

func frame(_ element: AXUIElement) -> CGRect {
    var rect = CGRect.zero
    if let value = attribute(element, "AXFrame") { AXValueGetValue(value as! AXValue, .cgRect, &rect) }
    return rect
}
