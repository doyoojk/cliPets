import AppKit
@preconcurrency import ApplicationServices
import QuartzCore

/// One pet representing one Claude session. Multiple PetOverlays can share a
/// terminal window — they're stacked horizontally along the window's top
/// edge and resize to fit the available width.
@MainActor
final class PetOverlay {
    let sessionId: String
    let pid: pid_t
    let windowID: CGWindowID

    /// Fired when the overlay tears itself down (window destroyed, app
    /// quit). AppDelegate uses this to remove the overlay and relayout
    /// siblings on the same window.
    var onClosed: (() -> Void)?

    /// Stack position on the window's top edge. 0 = rightmost. AppDelegate
    /// reassigns this when sibling pets are added or removed.
    var slotIndex: Int = 0 {
        didSet { invalidateLayout() }
    }

    /// Square size of the pet, in points. AppDelegate computes this per-window
    /// based on the number of pets sharing the window and the window width.
    var petSize: CGFloat = 70 {
        didSet { onPetSizeChanged() }
    }

    /// Distance from the window's right edge to the rightmost pet.
    private let petInset: CGFloat = 12
    /// Gap between adjacent pets.
    private let petGap: CGFloat = 6
    /// How far the paws dip below the terminal's top edge.
    private let petOverlap: CGFloat = 20

    private let element: AXUIElement
    private let frames: [CGImage]
    private let window: NSWindow
    private let contentView: PetContentView
    private let tracker: WindowTracker
    private var animationTimer: Timer?
    private var tickCount: Int = 0
    private var lastTerminalFrame: CGRect?
    private var isClosed = false
    private var isHidden = false

    // Most recent hook event info, surfaced when user clicks the pet.
    private var lastEventType: String?
    private var lastCwd: String?

    private var infoWindow: NSWindow?
    private var infoLabel: NSTextField?
    private var infoFadeTimer: Timer?

    init(
        sessionId: String,
        pid: pid_t,
        element: AXUIElement,
        windowID: CGWindowID,
        slotIndex: Int,
        petSize: CGFloat,
        frames: [CGImage]
    ) {
        self.sessionId = sessionId
        self.pid = pid
        self.windowID = windowID
        self.element = element
        self.frames = frames
        self.slotIndex = slotIndex
        self.petSize = petSize

        let w = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: petSize, height: petSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .normal
        w.collectionBehavior = [.transient, .ignoresCycle]
        w.ignoresMouseEvents = false
        w.hasShadow = false

        let cv = PetContentView(frame: NSRect(origin: .zero, size: CGSize(width: petSize, height: petSize)))
        cv.wantsLayer = true
        cv.layer?.magnificationFilter = .nearest
        cv.layer?.minificationFilter = .nearest
        cv.layer?.contentsGravity = .resize
        cv.layer?.contents = frames.first

        w.contentView = cv
        self.window = w
        self.contentView = cv
        self.tracker = WindowTracker(pid: pid, element: element, windowID: windowID)

        cv.onClick = { [weak self] in self?.showInfo() }

        tracker.onFrameChange = { [weak self] axFrame in
            self?.applyFrame(fromTopLeftRect: axFrame)
            self?.anchorAboveTerminalIfVisible()
        }
        tracker.onWindowLost = { [weak self] in
            self?.close()
        }
        tracker.onWindowHidden = { [weak self] in
            self?.hide()
        }
        tracker.onWindowShown = { [weak self] in
            self?.show()
        }
        tracker.onTerminalActivated = { [weak self] in
            self?.anchorAboveTerminalIfVisible()
        }
        tracker.start()

        startAnimationTimer()
    }

    func recordEvent(_ event: HookEvent) {
        lastEventType = event.eventType
        lastCwd = event.cwd
    }

    /// Called by AppDelegate's display link tick.
    func syncFromCGWindowList() {
        guard !isClosed, !isHidden else { return }
        guard let frame = AppDelegate.frameFromCGWindowList(windowID: windowID) else { return }
        applyFrame(fromTopLeftRect: frame)
    }

    /// Force an immediate reposition without waiting for the display-link tick.
    /// Call after slot/size changes to snap to the correct position right away.
    func forceSync() {
        lastTerminalFrame = nil
        syncFromCGWindowList()
    }

    func hide() {
        guard !isClosed, !isHidden else { return }
        isHidden = true
        infoFadeTimer?.invalidate()
        infoWindow?.orderOut(nil)
        window.orderOut(nil)
    }

    func show() {
        guard !isClosed else { return }
        isHidden = false
        // Force a reposition next sync.
        lastTerminalFrame = nil
        if let frame = AppDelegate.frameFromCGWindowList(windowID: windowID) {
            applyFrame(fromTopLeftRect: frame)
        }
        anchorAboveTerminalIfVisible()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        animationTimer?.invalidate()
        animationTimer = nil
        infoFadeTimer?.invalidate()
        infoFadeTimer = nil
        infoWindow?.orderOut(nil)
        infoWindow = nil
        tracker.stop()
        window.orderOut(nil)
        onClosed?()
    }

    // MARK: - Identification bubble

    private func showInfo() {
        let text = identifyingText()
        let info = ensureInfoWindow()
        let label = ensureInfoLabel(in: info)

        label.stringValue = text
        label.sizeToFit()

        let labelFrame = label.frame
        let bubbleSize = CGSize(width: labelFrame.width + 16, height: labelFrame.height + 8)

        let petFrame = window.frame
        let bubbleOrigin = NSPoint(
            x: petFrame.minX - bubbleSize.width - 6,
            y: petFrame.midY - bubbleSize.height / 2
        )
        info.setFrame(NSRect(origin: bubbleOrigin, size: bubbleSize), display: true)
        label.frame = NSRect(x: 8, y: 4, width: labelFrame.width, height: labelFrame.height)

        if !info.isVisible {
            info.orderFront(nil)
        }
        info.order(.above, relativeTo: Int(windowID))

        infoFadeTimer?.invalidate()
        infoFadeTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.infoWindow?.orderOut(nil)
            }
        }
    }

    private func identifyingText() -> String {
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "terminal"

        var parts: [String] = [appName]
        // Prefer the session's own cwd over the live AX window title — the
        // window title reflects whichever tab is currently active, which is
        // wrong when multiple sessions share a window (e.g. Ghostty tabs).
        if let cwd = lastCwd, !cwd.isEmpty {
            parts.append((cwd as NSString).lastPathComponent)
        } else {
            let title = (WindowTracker.copyAttribute(element, kAXTitleAttribute) as? String) ?? ""
            if !title.isEmpty { parts.append(title) }
        }
        if sessionId.count >= 8 {
            parts.append("session \(sessionId.prefix(8))")
        }
        return parts.joined(separator: " — ")
    }

    private func ensureInfoWindow() -> NSWindow {
        if let w = infoWindow { return w }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.collectionBehavior = [.transient, .ignoresCycle]
        w.ignoresMouseEvents = true
        w.hasShadow = false

        let bg = NSView(frame: NSRect(origin: .zero, size: CGSize(width: 200, height: 28)))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        bg.layer?.cornerRadius = 6
        w.contentView = bg
        infoWindow = w
        return w
    }

    private func ensureInfoLabel(in window: NSWindow) -> NSTextField {
        if let l = infoLabel { return l }
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.backgroundColor = .clear
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        window.contentView?.addSubview(label)
        infoLabel = label
        return label
    }

    // MARK: - Frame + Z-ordering

    private func applyFrame(fromTopLeftRect rect: CGRect) {
        if rect == lastTerminalFrame { return }
        lastTerminalFrame = rect
        let terminalNS = AppDelegate.nsRect(fromAX: rect)
        let xOffset = CGFloat(slotIndex) * (petSize + petGap)
        let origin = NSPoint(
            x: terminalNS.maxX - petSize - petInset - xOffset,
            y: terminalNS.maxY - petOverlap
        )
        window.setFrame(NSRect(origin: origin, size: CGSize(width: petSize, height: petSize)), display: false)
    }

    private func anchorAboveTerminalIfVisible() {
        guard !isClosed, !isHidden else { return }
        if !window.isVisible {
            window.orderFront(nil)
        }
        window.order(.above, relativeTo: Int(windowID))
    }

    private func invalidateLayout() {
        lastTerminalFrame = nil
    }

    private func onPetSizeChanged() {
        contentView.frame = NSRect(origin: .zero, size: CGSize(width: petSize, height: petSize))
        contentView.layer?.frame = contentView.bounds
        invalidateLayout()
    }

    // MARK: - Animation

    private func startAnimationTimer() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    private func tick() {
        tickCount += 1
        let cycle = tickCount % 36
        let frame = (cycle == 0 || cycle == 1) ? frames[1] : frames[0]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView.layer?.contents = frame
        CATransaction.commit()
    }
}

/// Custom content view that does pixel-perfect hit testing against the
/// current sprite frame, so transparent corners of the pet's bounding
/// window pass clicks through to whatever is underneath (the terminal).
@MainActor
final class PetContentView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        guard bounds.contains(local) else { return nil }

        guard
            let contents = layer?.contents,
            CFGetTypeID(contents as CFTypeRef) == CGImage.typeID
        else {
            return self
        }
        let image = contents as! CGImage
        return Self.alpha(at: local, in: bounds, of: image) > 0.4 ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    private static func alpha(at point: NSPoint, in viewBounds: NSRect, of image: CGImage) -> CGFloat {
        let imgW = image.width
        let imgH = image.height
        let nx = point.x / viewBounds.width
        let ny = (viewBounds.height - point.y) / viewBounds.height
        let imgX = Int(nx * CGFloat(imgW))
        let imgY = Int(ny * CGFloat(imgH))
        guard (0..<imgW).contains(imgX), (0..<imgH).contains(imgY) else { return 0 }

        guard
            let data = image.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return 1 }

        let bpp = image.bitsPerPixel / 8
        let bpr = image.bytesPerRow
        let offset = imgY * bpr + imgX * bpp
        switch image.alphaInfo {
        case .premultipliedLast, .last:
            return CGFloat(bytes[offset + bpp - 1]) / 255.0
        case .premultipliedFirst, .first:
            return CGFloat(bytes[offset]) / 255.0
        default:
            return 1
        }
    }
}
