import AppKit
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var spriteLayer: CALayer?
    private var timer: Timer?
    private var tickCount: Int = 0
    private var frames: [CGImage] = []
    private var tracker: WindowTracker?

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        tracker?.stop()
        timer?.invalidate()
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
        w.collectionBehavior = [.stationary, .ignoresCycle]
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
        t.start()
        self.tracker = t
    }

    private func reposition(terminalAxFrame: CGRect) {
        guard let window else { return }
        let terminalNS = Self.nsRect(fromAX: terminalAxFrame)
        // Top-right of the terminal. Paws dip `petOverlap` below the top edge
        // so it looks like the pet is hanging on by its paws.
        let petFrame = NSRect(
            x: terminalNS.maxX - petSize - petInset,
            y: terminalNS.maxY - petOverlap,
            width: petSize,
            height: petSize
        )
        window.setFrame(petFrame, display: true)
        orderPetAboveTerminal()
    }

    /// Pin the pet exactly one layer above the tracked terminal window in
    /// global Z-order. Unlike orderFront(), this does not raise the pet above
    /// unrelated windows — if a third window is raised above the terminal,
    /// both terminal and pet end up behind it.
    private func orderPetAboveTerminal() {
        guard let window else { return }
        if let wid = tracker?.trackedWindowID {
            window.order(.above, relativeTo: Int(wid))
        } else {
            window.orderFront(nil)
        }
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
