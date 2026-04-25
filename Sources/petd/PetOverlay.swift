import AppKit
@preconcurrency import ApplicationServices
import QuartzCore

/// One pet pinned to one terminal window. Owns its NSWindow, sprite layer,
/// AX observer (via WindowTracker), and animation state. AppDelegate holds
/// a dictionary of these keyed by CGWindowID.
@MainActor
final class PetOverlay {
    let windowID: CGWindowID
    let pid: pid_t

    /// Fired when the overlay tears itself down (window destroyed, app quit,
    /// etc.). AppDelegate uses this to remove the overlay from its registry.
    var onClosed: (() -> Void)?

    private let petSize: CGFloat = 70
    private let petInset: CGFloat = 60
    private let petOverlap: CGFloat = 20

    private let window: NSWindow
    private let spriteLayer: CALayer
    private let frames: [CGImage]
    private let tracker: WindowTracker
    private var animationTimer: Timer?
    private var tickCount: Int = 0
    private var lastTerminalFrame: CGRect?
    private var isClosed = false

    init(pid: pid_t, element: AXUIElement, windowID: CGWindowID, frames: [CGImage]) {
        self.pid = pid
        self.windowID = windowID
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
        w.ignoresMouseEvents = true
        w.hasShadow = false

        let contentView = NSView(frame: NSRect(origin: .zero, size: CGSize(width: petSize, height: petSize)))
        contentView.wantsLayer = true

        let layer = CALayer()
        layer.frame = contentView.bounds
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.contentsGravity = .resize
        layer.contents = frames.first
        contentView.layer?.addSublayer(layer)

        w.contentView = contentView
        self.window = w
        self.spriteLayer = layer
        self.tracker = WindowTracker(pid: pid, element: element, windowID: windowID)

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
        tracker.stop()
        window.orderOut(nil)
        onClosed?()
    }

    // MARK: - Internals

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
        spriteLayer.contents = frame
        CATransaction.commit()
    }
}
