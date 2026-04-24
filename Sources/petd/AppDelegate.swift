import AppKit
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var spriteLayer: CALayer?
    private var timer: Timer?
    private var tickCount: Int = 0
    private var frames: [CGImage] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }

        let spritePixelSize = 32
        let scale: CGFloat = 4
        let petSize = CGFloat(spritePixelSize) * scale // 128pt
        let screenFrame = screen.frame

        let windowFrame = NSRect(
            x: screenFrame.midX - petSize / 2,
            y: screenFrame.maxY - petSize - 48,
            width: petSize,
            height: petSize
        )

        let w = NSWindow(
            contentRect: windowFrame,
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

        let contentView = NSView(frame: NSRect(origin: .zero, size: windowFrame.size))
        contentView.wantsLayer = true

        let layer = CALayer()
        layer.frame = contentView.bounds
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.contentsGravity = .resize
        contentView.layer?.addSublayer(layer)

        w.contentView = contentView
        w.makeKeyAndOrderFront(nil)

        self.window = w
        self.spriteLayer = layer

        frames = [
            SpriteBuilder.makeCat(state: .idle),
            SpriteBuilder.makeCat(state: .blink),
        ]
        layer.contents = frames[0]

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    private func tick() {
        tickCount += 1
        guard let spriteLayer else { return }

        // Blink: hold eyes closed for 2 frames every ~3 seconds (36 ticks @ 12fps).
        let cycle = tickCount % 36
        let frame = (cycle == 0 || cycle == 1) ? frames[1] : frames[0]

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = frame
        CATransaction.commit()
    }
}
