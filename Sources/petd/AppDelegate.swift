import AppKit
import CoreVideo
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var spriteLayer: CALayer?
    private var timer: Timer?
    private var displayLink: CVDisplayLink?
    private var tickCount: Int = 0
    private var frames: [CGImage] = []
    private var tracker: WindowTracker?
    private var lastTerminalFrame: CGRect?
    private var eventServer: EventServer?

    // 32px sprite rendered at 1.5x nearest-neighbor. Phase 7 will swap to
    // proper sprite sheets at integer scales for crisp pixels.
    private let petSize: CGFloat = 70
    private let petInset: CGFloat = 60     // inset from terminal's right edge
    private let petOverlap: CGFloat = 20    // how far the paws dip below the terminal's top edge

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildOverlayWindow()
        buildSpriteFrames()
        startAnimationTimer()
        startWindowTracker()
        startFrameSync()
        startEventServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tracker?.stop()
        timer?.invalidate()
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        eventServer?.stop()
    }

    // MARK: - Overlay window

    private func buildOverlayWindow() {
        // Initial frame is offscreen; tracker repositions on first frame callback.
        let w = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: petSize, height: petSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        // Normal level so the pet hides behind any window placed in front of
        // the terminal. We keep it ordered above the terminal via orderFront()
        // whenever the terminal is moved/resized/activated.
        w.level = .normal
        // .transient: "hidden by Exposé and application hide" — keeps the pet
        // out of Mission Control / Exposé / App Exposé thumbnail overlays.
        // Do NOT add .stationary; it has the opposite effect ("unaffected by
        // Exposé, stays visible").
        w.collectionBehavior = [.transient, .ignoresCycle]
        w.ignoresMouseEvents = true
        w.hasShadow = false

        let contentView = NSView(frame: NSRect(origin: .zero, size: CGSize(width: petSize, height: petSize)))
        contentView.wantsLayer = true

        let layer = CALayer()
        layer.frame = contentView.bounds
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.contentsGravity = .resize
        contentView.layer?.addSublayer(layer)

        w.contentView = contentView
        self.window = w
        self.spriteLayer = layer
    }

    private func buildSpriteFrames() {
        frames = [
            SpriteBuilder.makeCat(state: .idle),
            SpriteBuilder.makeCat(state: .blink),
        ]
        spriteLayer?.contents = frames.first
    }

    private func startAnimationTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    private func tick() {
        tickCount += 1
        guard let spriteLayer, !frames.isEmpty else { return }
        let cycle = tickCount % 36
        let frame = (cycle == 0 || cycle == 1) ? frames[1] : frames[0]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = frame
        CATransaction.commit()
    }

    // MARK: - Window tracker

    private func startWindowTracker() {
        let t = WindowTracker()
        t.onFrameChange = { [weak self] axFrame in
            self?.reposition(terminalAxFrame: axFrame)
        }
        t.onWindowLost = { [weak self] in
            self?.window?.orderOut(nil)
        }
        t.onTerminalActivated = { [weak self] in
            // Terminal just became frontmost — re-anchor the pet one layer
            // above it. Any third window placed above the terminal covers
            // both terminal and pet.
            self?.orderPetAboveTerminal()
        }
        // Must be set before start(): start() fires onFrameChange synchronously,
        // and the callback needs tracker.trackedWindowID to anchor on first spawn.
        self.tracker = t
        t.start()
    }

    /// Called by the AX observer on move/resize and by the activation hook.
    /// Updates frame AND re-anchors Z-order.
    private func reposition(terminalAxFrame: CGRect) {
        applyFrame(fromTopLeftRect: terminalAxFrame)
        orderPetAboveTerminal()
    }

    /// Called by the display link every vblank. Only updates the pet's origin;
    /// Z-order is stable between focus changes so we skip the order() call to
    /// avoid hammering the window server at display rate.
    fileprivate func syncFrameFromTerminal() {
        guard
            let wid = tracker?.trackedWindowID,
            let frame = Self.frameFromCGWindowList(windowID: wid)
        else { return }
        applyFrame(fromTopLeftRect: frame)
    }

    private func applyFrame(fromTopLeftRect rect: CGRect) {
        guard let window else { return }
        if rect == lastTerminalFrame { return }
        lastTerminalFrame = rect
        let terminalNS = Self.nsRect(fromAX: rect)
        // Top-right of the terminal. Paws dip `petOverlap` below the top edge
        // so it looks like the pet is hanging on by its paws.
        let origin = NSPoint(
            x: terminalNS.maxX - petSize - petInset,
            y: terminalNS.maxY - petOverlap
        )
        // Pet's size never changes, so setFrameOrigin avoids the size-driven
        // layout pass that setFrame triggers.
        window.setFrameOrigin(origin)
    }

    /// Cheaper than AX for hot-loop polling: no IPC to the terminal app, just
    /// a cached lookup against the Window Server's snapshot. Returns the
    /// terminal's bounds in screen coordinates with origin at upper-left
    /// (same orientation as AX).
    private static func frameFromCGWindowList(windowID: CGWindowID) -> CGRect? {
        let opts: CGWindowListOption = .optionIncludingWindow
        guard
            let info = CGWindowListCopyWindowInfo(opts, windowID) as? [[String: Any]],
            let dict = info.first,
            let boundsCF = dict[kCGWindowBounds as String] as CFTypeRef?
        else { return nil }
        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsCF as! CFDictionary, &rect) else {
            return nil
        }
        return rect
    }

    /// Pin the pet exactly one layer above the tracked terminal window in
    /// global Z-order. Unlike orderFront(), this does not raise the pet above
    /// unrelated windows — if a third window is raised above the terminal,
    /// both terminal and pet end up behind it.
    private func orderPetAboveTerminal() {
        guard let window else { return }
        // Ensure the window is on screen first. order(.above, relativeTo:)
        // is supposed to bring an offscreen window in, but on a borderless
        // window owned by an .accessory-policy app it sometimes doesn't —
        // which manifested as the pet not rendering until the user clicked
        // the terminal.
        if !window.isVisible {
            window.orderFront(nil)
        }
        if let wid = tracker?.trackedWindowID {
            window.order(.above, relativeTo: Int(wid))
        }
    }

    private func startEventServer() {
        let path = Self.defaultSocketPath()
        let server = EventServer(socketPath: path)
        server.start { event in
            // Hops to main so AppKit work (animations in Phase 4+) is safe.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppDelegate.handleHookEvent(event)
                }
            }
        }
        eventServer = server
    }

    /// Phase 3 sink: log received events. Phase 4 will route them through
    /// the animation state machine.
    private static func handleHookEvent(_ event: HookEvent) {
        NSLog(
            "cliPets: hook \(event.eventType) tool=\(event.toolName ?? "-") session=\(event.sessionId?.prefix(8) ?? "-") cwd=\(event.cwd ?? "-")"
        )
    }

    static func defaultSocketPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.clipets/clipets.sock"
    }

    private func startFrameSync() {
        // CVDisplayLink phase-locks to the actual display refresh rate (120Hz
        // on ProMotion, 60Hz otherwise). Better than a Timer because the
        // callback fires near vblank, so our setFrame lands in the same
        // compositor frame as the terminal's update — keeping the pet
        // visually locked to the window during live drags.
        var link: CVDisplayLink?
        let err = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard err == kCVReturnSuccess, let link else {
            NSLog("cliPets: CVDisplayLink unavailable (\(err)); pet position will be tracker-driven only")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, cliPetsDisplayLinkCallback, refcon)
        CVDisplayLinkStart(link)
        self.displayLink = link
    }

    /// Converts an AX rect (top-left origin, Y downward, relative to primary display)
    /// to an NS rect (bottom-left origin, Y upward, primary screen's bottom-left at (0,0)).
    static func nsRect(fromAX axRect: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return .zero }
        return NSRect(
            x: axRect.origin.x,
            y: primary.frame.height - axRect.origin.y - axRect.size.height,
            width: axRect.size.width,
            height: axRect.size.height
        )
    }
}

/// CVDisplayLink output callback. Runs on the CV thread; hops to main to
/// touch AppKit. Captures AppDelegate via Unmanaged so we don't fight Swift's
/// strict concurrency about C function pointers.
private func cliPetsDisplayLinkCallback(
    displayLink: CVDisplayLink,
    inNow: UnsafePointer<CVTimeStamp>,
    inOutputTime: UnsafePointer<CVTimeStamp>,
    flagsIn: CVOptionFlags,
    flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    refcon: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let refcon else { return kCVReturnSuccess }
    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            appDelegate.syncFrameFromTerminal()
        }
    }
    return kCVReturnSuccess
}
