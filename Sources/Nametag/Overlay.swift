import AppKit

/// Draws custom names over Mission Control's "Desktop N" labels while it is open, and lets you
/// long-press a label to rename it in place.
final class OverlayController {
    private let store: NameStore
    private let reader = MissionControlReader()
    private let thumbnails = ThumbnailTracker()
    private let keys = KeyCapture()
    private let gestures = GestureMonitor()
    private var canvases: [CGDirectDisplayID: Canvas] = [:]
    private var timer: Timer?

    /// Mission Control is on screen: open, or mid-way through a close gesture.
    private var visible = false
    /// Set once a close has clearly been committed (the bar flying off on its own); pills stay
    /// hidden until Mission Control is open again.
    private var closeCommitted = false
    private var tickCount = 0
    /// How far into view the collapsed bar is, from 0 (above the screen) to 1 (in place).
    private var openness: CGFloat = 1
    private var swipeID: Int?
    private var swipeBeganOpen = false
    private var displays: [MissionControlDisplay] = []
    /// The last reading taken while nothing was moving. During a sideways swipe Mission Control reports
    /// shifted positions even though its bar holds still, so names stay where they were.
    private var restDisplays: [MissionControlDisplay] = []
    private var spaces: [Space] = []
    private var edit: Edit?

    private struct Edit {
        let spaceKey: String
        var text: String
        /// Like a freshly focused text field: the first keystroke replaces everything.
        var selectAll = true
        var caretVisible = true
        var caretToggledAt = Date()
    }

    // While idle, check for Mission Control a few times a second: each check wakes both Nametag and
    // WindowManager, so checking every frame costs real battery. A Mission Control swipe switches to
    // per-frame updates the moment it begins (see `start`), so swipes still get names instantly; the
    // F3 key, hot corners and the Dock show them within a quarter second.
    private let idleInterval: TimeInterval = 0.25
    private let visibleInterval: TimeInterval = 1.0 / 60
    private var interval: TimeInterval = 0
    // How Apple's bar follows a swipe, measured from screen recordings on macOS 27:
    // opening, the collapsed bar's labels come down 75pt over the whole swipe; closing, they hold
    // still for the first ~7% of the swipe, then rise 100pt per full swipe.
    private let openKnee: CGFloat = 1.0
    private let closeStart: CGFloat = 0.07
    private let closeKnee: CGFloat = 0.75
    /// How far the collapsed bar's labels travel: from just above the screen to their place.
    private let barTravel: CGFloat = 75
    /// How far an expanded bar's labels travel (its thumbnails rise from y≈61 to y≈-134).
    private let expandedTravel: CGFloat = 195
    /// Where an expanded bar's labels sat before the current swipe, per display.
    private var settledExpanded: [CGDirectDisplayID: [CGPoint]] = [:]

    init(store: NameStore) {
        self.store = store
    }

    func start() {
        gestures.onVerticalSwipeBegan = { [weak self] in
            DispatchQueue.main.async { self?.tick() }
        }
        gestures.start()
        prepareCanvases()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.prepareCanvases() }
        schedule(idleInterval)
    }

    /// Puts an empty canvas at the top of every display ahead of time. A window that first appears
    /// while Mission Control is opening is held back until the animation ends, so the canvases stay
    /// on screen all the time — empty and click-through whenever Mission Control is closed.
    private func prepareCanvases() {
        var present = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            present.insert(id)
            let canvas = canvases[id] ?? Canvas()
            canvases[id] = canvas
            canvas.cover(screen.frame)
        }
        for (id, canvas) in canvases where !present.contains(id) {
            canvas.orderOut(nil)
            canvases[id] = nil
        }
    }

    private func schedule(_ interval: TimeInterval) {
        guard interval != self.interval else { return }
        self.interval = interval
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let wasVisible = visible
        let open = store.enabled && reader.isOpen()
        // The moment a close gesture starts (swiping down, or up again) Mission Control drops its
        // Accessibility tree, but the bar stays on screen until the gesture finishes — or comes
        // back if it's cancelled. Keep going for as long as the bar is there.
        let nowVisible = open || (visible && store.enabled && thumbnails.barOnScreen())
        // Per-frame updates while Mission Control is up or a swipe is under way; a few checks a second otherwise.
        schedule(nowVisible || gestures.current?.vertical == true ? visibleInterval : idleInterval)
        if nowVisible != visible {
            visible = nowVisible
            if nowVisible {
                tickCount = 0
                thumbnails.reset()
                closeCommitted = false
                // Opened by a swipe: start above the screen and come down with the fingers.
                openness = gestures.current?.vertical == true ? 0 : 1
            } else {
                if edit != nil { commitEdit() }
                hideAll()
            }
        }
        guard visible else { return }
        if open { closeCommitted = false }

        followSwipe(wasVisible: wasVisible, open: open)

        // Accessibility carries the bar's destination, so read it every other frame while it's
        // there; during a close gesture keep the last reading for titles and order. While desktops
        // are being swiped sideways its positions are unreliable, and Apple's bar holds still anyway.
        // Early in a swipe-up Mission Control says it's open before its desktop list is readable; the
        // labels sit where they did last time, so keep the last good reading until then.
        if open, !gestures.horizontalSettling, tickCount % 2 == 0 || displays.isEmpty {
            let fresh = reader.read()
            if fresh.contains(where: { !$0.labels.isEmpty }) {
                // Only a reading that matches the one before it counts as resting.
                let steady = fresh.map { $0.labels.map(\.center) } == displays.map { $0.labels.map(\.center) }
                displays = fresh
                if steady, gestures.current == nil, !gestures.horizontalSettling, openness == 1 { restDisplays = fresh }
            }
        }
        if tickCount % 6 == 0 || spaces.isEmpty { spaces = Spaces.all() }
        tickCount += 1
        if var e = edit, Date().timeIntervalSince(e.caretToggledAt) > 0.5 {
            e.caretVisible.toggle()
            e.caretToggledAt = Date()
            edit = e
        }
        layout(open: open)
    }

    /// Moves `openness` with a vertical swipe. Mission Control reports nothing while fingers are on the
    /// trackpad, so this mirrors what it draws: the bar slides in from above as you swipe up, and back
    /// out as you swipe down; swiping up again while it's open leaves it in place.
    private func followSwipe(wasVisible: Bool, open: Bool) {
        var target: CGFloat = open ? 1 : 0
        if let swipe = gestures.current, swipe.vertical {
            if swipe.id != swipeID {
                swipeID = swipe.id
                swipeBeganOpen = wasVisible
            }
            let progress = CGFloat(swipe.progress)
            target = swipeBeganOpen
                ? 1 - min(1, max(0, (progress - closeStart) / closeKnee))
                : min(1, max(0, -progress / openKnee))
        }
        // A little smoothing for the gaps between trackpad events.
        openness += (target - openness) * 0.6
        if abs(target - openness) < 0.005 { openness = target }
    }

    private func layout(open: Bool) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let liveFrames = thumbnails.frames()
        // Clicks are only caught while nothing is moving, because window moves trail in Mission Control.
        let atRest = open && gestures.current == nil && !gestures.horizontalSettling && openness == 1
        var drawn = Set<CGDirectDisplayID>()

        for display in gestures.horizontalSettling && !restDisplays.isEmpty ? restDisplays : displays {
            // Screen geometry comes from CoreGraphics, never from Mission Control, whose frames shift
            // mid-swipe.
            let screen = CGDisplayBounds(display.displayID)
            let displaySpaces = Spaces.on(display: display.displayID, in: spaces)
            let labels = display.labels
            let live = liveFrames.filter { $0.midX >= screen.minX && $0.midX < screen.maxX }

            // Accessibility jumps straight to where an animation ends, which on screen is reached
            // almost at once, so pills follow it while the bar moves. Once the thumbnail windows
            // settle they're the ground truth (each label sits 11.5pt above its window's bottom edge).
            // During a close gesture the windows are the only thing tracking the bar, frame by frame.
            // During a sideways swipe Apple's bar holds still, but window positions and Accessibility
            // both slide with the desktops, so nothing live is trusted until it settles.
            // A sideways swipe slides a snapshot of the desktop, overlay included, while Apple's bar
            // holds still. Shifting names back against the slide flickers (the blur re-renders inside
            // the moving snapshot) and gets clipped (the snapshot only covers the screen), so names
            // step aside until the swipe settles.
            let sideways = gestures.horizontalSettling
            if sideways { continue }
            let windowsMatch = !sideways && !live.isEmpty && live.count == labels.count
            let useWindows = windowsMatch && thumbnails.isSettled && open
            let following = (gestures.current?.vertical == true && swipeBeganOpen) || gestures.horizontalSettling
            if !open {
                // A close that runs on its own (Esc, a click, the rest of a released swipe) moves the
                // bar faster than ~700pt/s; nothing reports where it is, so hide at once rather than
                // leave names floating behind.
                if thumbnails.verticalSpeed > 700 && !following { closeCommitted = true }
                if closeCommitted || !following { continue }
            }

            var expanded = useWindows || (labels.first?.expanded ?? false)
            var centers: [CGPoint]
            if useWindows {
                centers = live.map { CGPoint(x: $0.midX, y: $0.maxY - 11.5) }
                settledExpanded[display.displayID] = centers
            } else if sideways, let settled = settledExpanded[display.displayID], settled.count == labels.count {
                expanded = true
                centers = settled
            } else if !open, let settled = settledExpanded[display.displayID], settled.count == labels.count, windowsMatch {
                // An expanded bar being swiped away: its thumbnail windows' positions trail the
                // screen, so move the labels from where they last settled, with the swipe.
                expanded = true
                centers = settled.map { CGPoint(x: $0.x, y: $0.y - (1 - openness) * expandedTravel) }
            } else {
                let slide = (1 - openness) * barTravel
                centers = labels.map { CGPoint(x: $0.center.x, y: $0.center.y - slide) }
            }
            if open && !sideways && live.isEmpty { settledExpanded[display.displayID] = nil }

            var specs: [PillView.Spec] = []
            var hits: [Canvas.Hit] = []
            for (i, label) in labels.enumerated() {
                guard let space = match(label, at: i, labelCount: labels.count, in: displaySpaces),
                      space.number != nil  // leave full-screen app labels alone
                else { continue }

                // Keep long names from running into the neighbouring labels.
                let gaps = [i > 0 ? centers[i].x - centers[i - 1].x : nil,
                            i < centers.count - 1 ? centers[i + 1].x - centers[i].x : nil].compactMap { $0 }

                let content: PillView.Content?
                if let e = edit, e.spaceKey == space.key {
                    content = .editing(e.text, selectAll: e.selectAll, caretVisible: e.caretVisible)
                } else {
                    content = store.name(for: space).map { .name($0) }  // unnamed: nothing drawn
                }
                if let content {
                    specs.append(PillView.Spec(
                        content: content,
                        covering: label.title,
                        center: CGPoint(x: centers[i].x - screen.minX,
                                        y: Canvas.height - (centers[i].y - screen.minY)),
                        maxWidth: (gaps.min() ?? 260) - 3,
                        expanded: expanded
                    ))
                }

                // Every desktop, named or not, can be clicked and long-pressed.
                if atRest {
                    let size = PillView.coverSize(for: label.title, expanded: expanded)
                    let center = CGPoint(x: centers[i].x - screen.minX, y: Canvas.height - (centers[i].y - screen.minY))
                    hits.append(Canvas.Hit(
                        frame: NSRect(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded(),
                                      width: size.width, height: size.height),
                        onTap: { [weak self] in self?.tapped(label) },
                        onLongPress: { [weak self] in self?.beginEdit(space) }
                    ))
                }
            }

            let canvas = canvases[display.displayID] ?? Canvas()
            canvases[display.displayID] = canvas
            canvas.cover(NSRect(x: screen.minX, y: primaryHeight - screen.maxY,
                                width: screen.width, height: screen.height))
            canvas.show(specs, hits: hits)
            drawn.insert(display.displayID)
        }
        for (id, canvas) in canvases where !drawn.contains(id) { canvas.show([]) }
    }

    /// Mission Control lists a display's spaces in the same order CGS does. If the counts disagree
    /// (mid-reorder, or a desktop being added), fall back to the "Desktop N" title.
    private func match(_ label: MissionControlLabel, at index: Int, labelCount: Int, in spaces: [Space]) -> Space? {
        if spaces.count == labelCount { return spaces[index] }
        guard label.title.hasPrefix("Desktop "), let n = Int(label.title.dropFirst(8)) else { return nil }
        return spaces.first { $0.number == n }
    }

    private func hideAll() {
        for canvas in canvases.values { canvas.show([]) }
    }

    // MARK: Interaction

    private func tapped(_ label: MissionControlLabel) {
        // While renaming, a click on a label just finishes the rename, like clicking away from a text field.
        if edit != nil { commitEdit(); return }
        reader.press(label)
    }

    private func beginEdit(_ space: Space) {
        if edit != nil { commitEdit() }
        guard keys.start({ [weak self] event in self?.handleKey(event) }) else { return }
        edit = Edit(spaceKey: space.key, text: store.name(for: space) ?? "")
        layout(open: reader.isOpen())
    }

    private func handleKey(_ event: NSEvent) {
        guard var e = edit else { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        let characters = event.charactersIgnoringModifiers?.lowercased()

        switch event.keyCode {
        case 36, 76: commitEdit(); return   // Return, Enter
        case 53: cancelEdit(); return       // Escape
        case 51:                            // Delete
            if e.selectAll || modifiers.contains(.command) { e.text = "" } else if !e.text.isEmpty { e.text.removeLast() }
            e.selectAll = false
        default:
            if modifiers == .command, characters == "a" {
                e.selectAll = true
            } else if modifiers == .command, characters == "v" {
                let pasted = NSPasteboard.general.string(forType: .string)?.components(separatedBy: .newlines).first ?? ""
                e.text = (e.selectAll ? "" : e.text) + pasted
                e.selectAll = false
            } else if modifiers.subtracting(.option).isEmpty, let typed = event.characters, isPrintable(typed) {
                e.text = (e.selectAll ? "" : e.text) + typed
                e.selectAll = false
            } else {
                return
            }
        }
        e.text = String(e.text.prefix(40))
        e.caretVisible = true
        e.caretToggledAt = Date()
        edit = e
        layout(open: reader.isOpen())
    }

    private func isPrintable(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)  // arrows, F-keys
        }
    }

    private func commitEdit() {
        guard let e = edit else { return }
        if let space = spaces.first(where: { $0.key == e.spaceKey }) {
            store.setName(e.text, for: space)  // empty resets to "Desktop N"
        }
        endEdit()
    }

    private func cancelEdit() {
        endEdit()
    }

    private func endEdit() {
        keys.stop()
        edit = nil
        if visible { layout(open: reader.isOpen()) }
    }
}

/// One display's drawing surface: a fixed, click-through window across the top of the screen with a
/// pill view per label. While Mission Control is on screen, WindowManager trails window moves by
/// several frames (measured on macOS 27), but drawing inside a window that never moves shows up at
/// once — so pills move as views, never as windows.
final class Canvas: NSPanel {
    static let height: CGFloat = 260
    private var pills: [PillView] = []
    private var hitViews: [PressView] = []

    /// A label that can be clicked (switch desktop) or long-pressed (rename), in canvas coordinates.
    struct Hit {
        let frame: NSRect
        let onTap: () -> Void
        let onLongPress: () -> Void
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = NSView()
        contentView?.wantsLayer = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Spans the top of the display whose AppKit frame is `display`.
    func cover(_ display: NSRect) {
        let frame = NSRect(x: display.minX, y: display.maxY - Self.height, width: display.width, height: Self.height)
        if frame != self.frame { setFrame(frame, display: false) }
        if !isVisible { orderFrontRegardless() }
    }

    /// Clicks are caught only on `hits`; everywhere else the canvas is fully transparent, so clicks
    /// fall through to Mission Control. (Separate click-catching windows don't work: Mission Control
    /// never shows windows that first appear while it's open.)
    func show(_ specs: [PillView.Spec], hits: [Hit] = []) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while pills.count < specs.count {
            let pill = PillView()
            contentView?.addSubview(pill)
            pills.append(pill)
        }
        for (pill, spec) in zip(pills, specs) {
            pill.apply(spec)
            pill.isHidden = false
        }
        for pill in pills.dropFirst(specs.count) { pill.isHidden = true }

        while hitViews.count < hits.count {
            let view = PressView()
            view.wantsLayer = true
            // A fully transparent area lets clicks fall through; 1% white catches them invisibly.
            view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.01).cgColor
            contentView?.addSubview(view, positioned: .above, relativeTo: nil)
            hitViews.append(view)
        }
        for (view, hit) in zip(hitViews, hits) {
            if view.frame != hit.frame { view.frame = hit.frame }
            view.onTap = hit.onTap
            view.onLongPress = hit.onLongPress
            view.isHidden = false
        }
        for view in hitViews.dropFirst(hits.count) { view.isHidden = true }
        CATransaction.commit()
        ignoresMouseEvents = hits.isEmpty
    }
}

/// A name drawn over one "Desktop N" label, styled after Apple's own label pill (measured on macOS 27:
/// 24pt tall, ~12pt side padding, 5pt corners, 13.5pt regular text; 12pt text under the thumbnails of
/// the expanded bar).
final class PillView: NSView {
    enum Content {
        case name(String)
        case editing(String, selectAll: Bool, caretVisible: Bool)
    }

    struct Spec {
        let content: Content
        /// Apple's label underneath, which the pill must fully cover.
        let covering: String
        /// In canvas coordinates.
        let center: CGPoint
        let maxWidth: CGFloat
        let expanded: Bool
    }

    private let background = NSVisualEffectView()
    private let tint = NSView()
    private let text = PillText()

    private static let cornerRadius: CGFloat = 5
    /// Clips the blur to exactly the same rounded rect as the tint on top of it.
    private static let mask: NSImage = {
        let r = cornerRadius
        let image = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }()

    static func font(expanded: Bool) -> NSFont { .systemFont(ofSize: expanded ? 12 : 13.5) }
    private static func padding(expanded: Bool) -> CGFloat { expanded ? 16 : 24 }

    /// The size of Apple's pill for a label, which is also the area that catches clicks.
    static func coverSize(for original: String, expanded: Bool) -> NSSize {
        let width = (original as NSString).size(withAttributes: [.font: font(expanded: expanded)]).width
        return NSSize(width: (width + padding(expanded: expanded)).rounded(.up), height: expanded ? 18 : 24)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        // The blur hides Apple's label underneath; the white tint on top gives it the same light
        // pill look as Apple's highlighted label.
        background.material = .hudWindow
        background.appearance = NSAppearance(named: .darkAqua)
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.mask
        background.autoresizingMask = [.width, .height]
        addSubview(background)

        tint.wantsLayer = true
        tint.layer?.cornerRadius = Self.cornerRadius
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)

        text.autoresizingMask = [.width, .height]
        addSubview(text)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ spec: Spec) {
        let font = Self.font(expanded: spec.expanded)
        let padding = Self.padding(expanded: spec.expanded)
        let cover = Self.coverSize(for: spec.covering, expanded: spec.expanded)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]

        let title = NSMutableAttributedString()
        var tintColor = NSColor.white.withAlphaComponent(0.28)
        switch spec.content {
        case .name(let name):
            title.append(NSAttributedString(string: name, attributes: attributes))
        case .editing(let typed, let selectAll, let caretVisible):
            paragraph.lineBreakMode = .byTruncatingHead  // keep the caret end visible
            var selected = attributes
            if selectAll { selected[.backgroundColor] = NSColor.selectedTextBackgroundColor }
            title.append(NSAttributedString(string: typed, attributes: selected))
            var caret = attributes
            caret[.foregroundColor] = NSColor.white.withAlphaComponent(caretVisible ? 1 : 0)
            title.append(NSAttributedString(string: "▏", attributes: caret))
            tintColor = NSColor.controlAccentColor.withAlphaComponent(0.45)
        }

        // Exactly covers Apple's pill; grows for longer names, but never into the neighbouring label.
        let width = min(max(title.size().width + padding, cover.width), max(spec.maxWidth, cover.width)).rounded(.up)
        tint.layer?.backgroundColor = tintColor.cgColor
        text.string = title

        // Whole points only: at a fractional origin the blur and tint round differently and a dark
        // hairline shows along one edge.
        let frame = NSRect(x: (spec.center.x - width / 2).rounded(), y: (spec.center.y - cover.height / 2).rounded(),
                           width: width, height: cover.height)
        if frame != self.frame { self.frame = frame }
    }
}

/// Draws the name the way Mission Control draws its labels: centered, white, no font smoothing
/// (with smoothing, white text on a translucent background looks a weight heavier than Apple's).
private final class PillText: NSView {
    var string = NSAttributedString() {
        didSet { if string != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setAllowsFontSmoothing(false)
        let height = string.size().height
        let rect = NSRect(x: 6, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 12, height: height)
        string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// Tells a quick click (switch desktop) apart from a long press (rename).
private final class PressView: NSView {
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?

    private var timer: Timer?
    private var downLocation: NSPoint?
    private var longPressed = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downLocation = NSEvent.mouseLocation
        longPressed = false
        let timer = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.longPressed = true
            self?.onLongPress?()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downLocation else { return }
        let now = NSEvent.mouseLocation
        if hypot(now.x - start.x, now.y - start.y) > 6 {
            timer?.invalidate()
            downLocation = nil  // a drag is neither a tap nor a long press
        }
    }

    override func mouseUp(with event: NSEvent) {
        timer?.invalidate()
        if downLocation != nil, !longPressed { onTap?() }
        downLocation = nil
    }
}
