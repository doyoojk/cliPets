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

    private let petSize: CGFloat = 128    // 32px sprite * 4x scale
    private let petInset: CGFloat = 16    // inset from terminal window's left edge

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
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
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
        t.start()
        self.tracker = t
    }

    private func reposition(terminalAxFrame: CGRect) {
        guard let window else { return }
        let terminalNS = Self.nsRect(fromAX: terminalAxFrame)
        // Pet sits on top edge: bottom of pet aligns with window's top.
        let petFrame = NSRect(
            x: terminalNS.minX + petInset,
            y: terminalNS.maxY,
            width: petSize,
            height: petSize
        )
        window.setFrame(petFrame, display: true)
        window.orderFront(nil)
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
