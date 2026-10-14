import AppKit

/// The menu-bar icon: the tag from the app icon, drawn as a vector template image so it stays crisp
/// at any scale and macOS tints it to match the menu bar.
enum TagIcon {
    /// Filled when Nametag is on, outlined when it's off.
    static func image(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = tagPath(in: rect)
            if filled {
                path.windingRule = .evenOdd  // punches the hole through
                path.fill()
            } else {
                path.lineWidth = 1.3
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Nametag"
        return image
    }

    private static func tagPath(in rect: NSRect) -> NSBezierPath {
        // A luggage tag 10.5 × 14pt: straight sides, a clipped "roof", rounded corners.
        let w: CGFloat = 10.5, h: CGFloat = 14, shoulder: CGFloat = 9.2, roof: CGFloat = 3
        let outline = roundedPolygon([
            CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: shoulder),
            CGPoint(x: w - roof, y: h), CGPoint(x: roof, y: h), CGPoint(x: 0, y: shoulder),
        ], radius: 1.6)
        outline.append(NSBezierPath(ovalIn: NSRect(x: w / 2 - 1.5, y: h - 4.4, width: 3, height: 3)))

        // Tilt it like the tag on the app icon and center it.
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.rotate(byDegrees: 14)
        transform.translateX(by: -w / 2, yBy: -h / 2)
        outline.transform(using: transform as AffineTransform)
        return outline
    }

    private static func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let n = points.count
        let start = CGPoint(x: (points[n - 1].x + points[0].x) / 2, y: (points[n - 1].y + points[0].y) / 2)
        path.move(to: start)
        for i in 0..<n {
            path.appendArc(from: points[i], to: points[(i + 1) % n], radius: radius)
        }
        path.close()
        return path
    }
}
