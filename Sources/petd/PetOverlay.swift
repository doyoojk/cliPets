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

    let element: AXUIElement
    private let sprites: [PetAnimationState: [CGImage]]
    private let window: NSWindow
    private let contentView: PetContentView
    private let tracker: WindowTracker
    private var animationTimer: Timer?
    private var lastTerminalFrame: CGRect?
    private var isClosed = false
    private var isHidden = false

    // Animation state machine
    private var currentState: PetAnimationState = .idle
    private var stateAge: Int = 0       // ticks elapsed in the current state
    private var cyclesLeft: Int = 0     // remaining cycles for one-shot states
    private var stateTimeoutTimer: Timer?

    // Speech bubble
    private var bubbleWindow: NSWindow?
    private var bubbleLayer: CALayer?
    private var bubbleHideTimer: Timer?

    // Most recent hook event info, surfaced when user clicks the pet.
    private var lastEventType: String?
    private var lastCwd: String?
    private var sessionName: String?

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
        sprites: [PetAnimationState: [CGImage]]
    ) {
        self.sessionId = sessionId
        self.pid = pid
        self.windowID = windowID
        self.element = element
        self.sprites = sprites
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
        w.level = .floating
        w.collectionBehavior = [.transient, .ignoresCycle]
        w.ignoresMouseEvents = false
        w.hasShadow = false

        let cv = PetContentView(frame: NSRect(origin: .zero, size: CGSize(width: petSize, height: petSize)))
        cv.wantsLayer = true
        cv.layer?.magnificationFilter = .nearest
        cv.layer?.minificationFilter = .nearest
        cv.layer?.contentsGravity = .resize
        cv.layer?.contents = sprites[.idle]?.first

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
        if sessionName == nil {
            sessionName = Self.readSessionName(sessionId: sessionId)
        }
        switch event.eventType {
        case "Stop":
            triggerAnimation(.celebrate)
        case "Notification":
            triggerAnimation(.alert)
        case "UserPromptSubmit":
            triggerAnimation(.listening)
        case "PreToolUse":
            switch event.toolName {
            case "Bash":            triggerAnimation(.working)
            case "Write", "Edit":   triggerAnimation(.writing)
            default:                break
            }
        default:
            break
        }
    }

    private func triggerAnimation(_ state: PetAnimationState) {
        // Alert loops until any new event replaces it; otherwise respect priority.
        let canInterrupt = currentState == .alert || state.priority >= currentState.priority
        guard canInterrupt else { return }
        stateTimeoutTimer?.invalidate()
        stateTimeoutTimer = nil
        currentState = state
        stateAge = 0
        switch state {
        case .celebrate:
            cyclesLeft = 2
        case .alert:
            cyclesLeft = 0
        case .listening, .working, .writing:
            cyclesLeft = 0
            stateTimeoutTimer = Timer.scheduledTimer(
                withTimeInterval: 8.0, repeats: false
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.transitionToIdle() }
            }
        case .idle:
            cyclesLeft = 0
        }
        // Bubbles disabled until proper pixel-art sprites are created.
        // if let text = state.bubbleText {
        //     showBubble(text, autohide: state != .alert)
        // } else {
        //     hideBubble()
        // }
    }

    private func transitionToIdle() {
        currentState = .idle
        stateAge = 0
        cyclesLeft = 0
        stateTimeoutTimer = nil
        hideBubble()
    }

    /// Read the user-assigned session name from ~/.claude/sessions/<pid>.json.
    private static func readSessionName(sessionId: String) -> String? {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for file in files where file.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let sid = obj["sessionId"] as? String,
                sid == sessionId,
                let name = obj["name"] as? String,
                !name.isEmpty
            else { continue }
            return name
        }
        return nil
    }

    /// Called by AppDelegate's display link tick when the group's best frame is known.
    /// Pushes the frame directly without trying to look it up again.
    func applySharedFrame(_ frame: CGRect) {
        guard !isClosed, !isHidden else { return }
        applyFrame(fromTopLeftRect: frame, animated: false)
    }

    /// Called by AppDelegate's display link tick (single-pet windows only).
    func syncFromCGWindowList() {
        guard !isClosed, !isHidden else { return }
        guard let frame = currentTerminalFrame() else { return }
        applyFrame(fromTopLeftRect: frame, animated: false)
    }

    /// Force an immediate reposition without waiting for the display-link tick.
    /// Call after slot/size changes to snap to the correct position right away.
    func forceSync(animated: Bool = false) {
        lastTerminalFrame = nil
        guard !isClosed, !isHidden else { return }
        guard let frame = currentTerminalFrame() else { return }
        applyFrame(fromTopLeftRect: frame, animated: animated)
        anchorAboveTerminalIfVisible()
    }

    /// Returns the terminal window frame, preferring CGWindowList (cheap) and
    /// falling back to the AX element. The fallback matters for Ghostty: all
    /// tabs are grouped under one canonical CGWindowID, so background tabs are
    /// absent from CGWindowList but their AX element always reports the current
    /// OS window position.
    private func currentTerminalFrame() -> CGRect? {
        if let f = AppDelegate.frameFromCGWindowList(windowID: windowID) { return f }
        return WindowTracker.frame(of: element)
    }

    func hide() {
        guard !isClosed, !isHidden else { return }
        isHidden = true
        infoFadeTimer?.invalidate()
        infoWindow?.orderOut(nil)
        bubbleWindow?.orderOut(nil)
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
        stateTimeoutTimer?.invalidate()
        stateTimeoutTimer = nil
        bubbleHideTimer?.invalidate()
        bubbleHideTimer = nil
        infoFadeTimer?.invalidate()
        infoFadeTimer = nil
        bubbleWindow?.orderOut(nil)
        bubbleWindow = nil
        bubbleLayer = nil
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
        if let name = sessionName, !name.isEmpty {
            parts.append(name)
        } else if let cwd = lastCwd, !cwd.isEmpty {
            parts.append((cwd as NSString).lastPathComponent)
        } else {
            let title = (WindowTracker.copyAttribute(element, kAXTitleAttribute) as? String) ?? ""
            if !title.isEmpty { parts.append(title) }
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

    // MARK: - Speech bubble

    private func showBubble(_ text: String, autohide: Bool) {
        bubbleHideTimer?.invalidate()
        bubbleHideTimer = nil

        guard let (image, size) = BubbleRenderer.render(text: text) else { return }

        let bw = ensureBubbleWindow()
        let bl = ensureBubbleLayer(in: bw)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bl.contents = image
        bl.frame = CGRect(origin: .zero, size: size)
        CATransaction.commit()

        positionBubble(size: size)
        bw.alphaValue = 1
        if !bw.isVisible { bw.orderFront(nil) }

        if autohide {
            bubbleHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideBubble() }
            }
        }
    }

    private func hideBubble() {
        bubbleHideTimer?.invalidate()
        bubbleHideTimer = nil
        guard let bw = bubbleWindow, bw.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            bw.animator().alphaValue = 0
        } completionHandler: { [weak bw] in
            MainActor.assumeIsolated { bw?.orderOut(nil) }
        }
    }

    private func positionBubble(size: CGSize) {
        guard let bw = bubbleWindow else { return }
        let petFrame = window.frame
        let origin = NSPoint(
            x: petFrame.midX - size.width / 2,
            y: petFrame.maxY + 4
        )
        bw.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func ensureBubbleWindow() -> NSWindow {
        if let w = bubbleWindow { return w }
        let w = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true
        w.hasShadow = false
        let cv = NSView(frame: .zero)
        cv.wantsLayer = true
        w.contentView = cv
        bubbleWindow = w
        return w
    }

    private func ensureBubbleLayer(in w: NSWindow) -> CALayer {
        if let l = bubbleLayer { return l }
        let l = CALayer()
        l.contentsGravity = .resize
        l.magnificationFilter = .nearest
        w.contentView?.layer?.addSublayer(l)
        bubbleLayer = l
        return l
    }

    // MARK: - Frame + Z-ordering

    private func applyFrame(fromTopLeftRect rect: CGRect, animated: Bool = false) {
        if rect == lastTerminalFrame { return }
        lastTerminalFrame = rect
        let terminalNS = AppDelegate.nsRect(fromAX: rect)
        let xOffset = CGFloat(slotIndex) * (petSize + petGap)
        let origin = NSPoint(
            x: terminalNS.maxX - petSize - petInset - xOffset,
            y: terminalNS.maxY - petOverlap
        )
        let newFrame = NSRect(origin: origin, size: CGSize(width: petSize, height: petSize))
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(newFrame, display: true)
            }
        } else {
            window.setFrame(newFrame, display: false)
        }
        repositionInfoWindowIfVisible()
        if let bw = bubbleWindow, bw.isVisible {
            positionBubble(size: bw.frame.size)
        }
    }

    private func repositionInfoWindowIfVisible() {
        guard let info = infoWindow, info.isVisible else { return }
        guard let label = infoLabel else { return }
        let bubbleSize = CGSize(width: label.frame.width + 16, height: label.frame.height + 8)
        let petFrame = window.frame
        let bubbleOrigin = NSPoint(
            x: petFrame.minX - bubbleSize.width - 6,
            y: petFrame.midY - bubbleSize.height / 2
        )
        info.setFrame(NSRect(origin: bubbleOrigin, size: bubbleSize), display: false)
    }

    private func anchorAboveTerminalIfVisible() {
        guard !isClosed, !isHidden else { return }
        window.orderFront(nil)
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
        // Advance one-shot states and detect cycle completion before rendering.
        switch currentState {
        case .celebrate:
            let cycleLen = 12
            if stateAge > 0 && stateAge % cycleLen == 0 {
                if cyclesLeft <= 1 { transitionToIdle() }
                else { cyclesLeft -= 1 }
            }
        case .alert:
            break // loops until replaced by a new event
        default:
            break
        }

        let frames = sprites[currentState, default: sprites[.idle, default: []]]
        guard !frames.isEmpty else { stateAge += 1; return }

        let image: CGImage
        switch currentState {
        case .idle:
            // Blink on the last 2 ticks of a 36-tick cycle.
            let pos = stateAge % 36
            image = pos >= 34 ? frames[min(1, frames.count - 1)] : frames[0]

        case .listening:
            // Same timing as idle — slow blink every 36 ticks.
            let pos = stateAge % 36
            image = pos >= 34 ? frames[min(1, frames.count - 1)] : frames[0]

        case .working, .writing:
            // Alternate paw height every 3 ticks.
            let pos = stateAge % 6
            image = pos < 3 ? frames[0] : frames[min(1, frames.count - 1)]

        case .celebrate:
            // squat(2) → jump(3) → peak(4) → land(3) = 12-tick cycle
            let pos = stateAge % 12
            let idx = pos < 2 ? 0 : pos < 5 ? 1 : pos < 9 ? 2 : 3
            image = frames[min(idx, frames.count - 1)]

        case .alert:
            // wide-eyes(2) → hop(3) → settle(3) = 8-tick cycle
            let pos = stateAge % 8
            let idx = pos < 2 ? 0 : pos < 5 ? 1 : 2
            image = frames[min(idx, frames.count - 1)]
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView.layer?.contents = image
        CATransaction.commit()

        stateAge += 1
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
