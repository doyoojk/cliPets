import AppKit
@preconcurrency import ApplicationServices
import QuartzCore

/// One pet pinned to one terminal window. Owns its NSWindow, sprite layer,
/// AX observer (via WindowTracker), and animation state. Click the cat to
/// show a small identification bubble naming the terminal and last
/// session.
@MainActor
final class PetOverlay {
    let windowID: CGWindowID
    let pid: pid_t

    /// Fired when the overlay tears itself down (window destroyed, app
    /// quit, etc.). AppDelegate uses this to remove the overlay from its
    /// registry.
    var onClosed: (() -> Void)?

    private let petSize: CGFloat = 70
    private let petInset: CGFloat = 60
    private let petOverlap: CGFloat = 20

    private let window: NSWindow
    private let contentView: PetContentView
    private let frames: [CGImage]
    private let element: AXUIElement
    private let tracker: WindowTracker
    private var animationTimer: Timer?
    private var tickCount: Int = 0
    private var lastTerminalFrame: CGRect?
    private var isClosed = false

    // Most recent hook event info, surfaced when user clicks the pet.
    private var lastSessionId: String?
    private var lastEventType: String?
    private var lastCwd: String?

    private var infoWindow: NSWindow?
    private var infoLabel: NSTextField?
    private var infoFadeTimer: Timer?

    init(pid: pid_t, element: AXUIElement, windowID: CGWindowID, frames: [CGImage]) {
        self.pid = pid
        self.windowID = windowID
        self.element = element
        self.frames = frames

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
        // Catch clicks so we can show the identification bubble. Pixel-perfect
        // hit testing in PetContentView ensures clicks on transparent areas of
        // the bounding box still pass through to the terminal underneath.
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

        cv.onClick = { [weak self] in
            self?.showInfo()
        }

        tracker.onFrameChange = { [weak self] axFrame in
            self?.applyFrame(fromTopLeftRect: axFrame)
            self?.anchorAboveTerminal()
        }
        tracker.onWindowLost = { [weak self] in
            self?.close()
        }
        tracker.onTerminalActivated = { [weak self] in
            self?.anchorAboveTerminal()
        }
        tracker.start()

        startAnimationTimer()
    }

    /// Capture context from the latest hook event for this window. Surfaced
    /// in the click-to-identify bubble.
    func recordEvent(_ event: HookEvent) {
        lastSessionId = event.sessionId
        lastEventType = event.eventType
        lastCwd = event.cwd
    }

    /// Called by AppDelegate's display link tick. Updates origin only — Z
    /// order is stable between focus changes.
    func syncFromCGWindowList() {
        guard !isClosed else { return }
        guard let frame = AppDelegate.frameFromCGWindowList(windowID: windowID) else { return }
        applyFrame(fromTopLeftRect: frame)
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
        // Bubble sits to the LEFT of the pet (pet is on the right side of the
        // terminal; left side has more room). Vertically centered with the pet.
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
        let title = (WindowTracker.copyAttribute(element, kAXTitleAttribute) as? String) ?? ""

        var parts: [String] = [appName]
        if !title.isEmpty {
            parts.append(title)
        } else if let cwd = lastCwd {
            // Fall back to the cwd's last component if the window has no title
            parts.append((cwd as NSString).lastPathComponent)
        }
        if let sessionId = lastSessionId, sessionId.count >= 8 {
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
        let origin = NSPoint(
            x: terminalNS.maxX - petSize - petInset,
            y: terminalNS.maxY - petOverlap
        )
        window.setFrameOrigin(origin)
    }

    private func anchorAboveTerminal() {
        if !window.isVisible {
            window.orderFront(nil)
        }
        window.order(.above, relativeTo: Int(windowID))
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

    /// Always accept clicks even when our window/app isn't key — the user
    /// shouldn't have to focus the pet first.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // hitTest's `point` is in superview coordinates. Convert to local.
        let local = NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        guard bounds.contains(local) else { return nil }

        guard
            let contents = layer?.contents,
            CFGetTypeID(contents as CFTypeRef) == CGImage.typeID
        else {
            // Fallback: if we can't read pixels, catch the click anyway.
            return self
        }
        let image = contents as! CGImage
        return Self.alpha(at: local, in: bounds, of: image) > 0.4 ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    /// Sample alpha at a view-local point, mapping to the sprite's source
    /// pixel grid. View coords are bottom-left-origin; CGImage data is
    /// top-left.
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
