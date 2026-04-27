import AppKit
import QuartzCore

/// One pet representing one Claude session. All pets float in a horizontal
/// row just below the menu bar, always visible regardless of which terminal
/// window or tab is in front.
@MainActor
final class PetOverlay {
    let sessionId: String

    /// Fired when the overlay tears itself down. AppDelegate uses this to
    /// remove the overlay and relayout siblings.
    var onClosed: (() -> Void)?

    /// Position in the screen-top row. 0 = rightmost. AppDelegate reassigns
    /// this when sessions are added or removed.
    var slotIndex: Int = 0 {
        didSet { applyScreenPosition() }
    }

    /// Square size of the pet, in points.
    var petSize: CGFloat = 44 {
        didSet { onPetSizeChanged() }
    }

    private let petInset: CGFloat = 12
    private let petGap: CGFloat = 6

    private let frames: [CGImage]
    private let window: NSWindow
    private let contentView: PetContentView
    private var animationTimer: Timer?
    private var tickCount: Int = 0
    private var isClosed = false
    private var isHidden = false

    private var lastCwd: String?
    private var lastEventType: String?

    private var infoWindow: NSWindow?
    private var infoLabel: NSTextField?
    private var infoFadeTimer: Timer?

    init(sessionId: String, slotIndex: Int, petSize: CGFloat, frames: [CGImage]) {
        self.sessionId = sessionId
        self.slotIndex = slotIndex
        self.petSize = petSize
        self.frames = frames

        let w = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: petSize, height: petSize),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
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

        cv.onClick = { [weak self] in self?.showInfo() }

        applyScreenPosition()
        window.orderFront(nil)
        startAnimationTimer()
    }

    func recordEvent(_ event: HookEvent) {
        lastEventType = event.eventType
        lastCwd = event.cwd
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
        applyScreenPosition()
        window.orderFront(nil)
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
        window.orderOut(nil)
        onClosed?()
    }

    /// Called by AppDelegate when the screen configuration may have changed.
    func syncPosition() {
        guard !isClosed, !isHidden else { return }
        applyScreenPosition()
    }

    // MARK: - Screen positioning

    func applyScreenPosition() {
        guard let screen = NSScreen.main else { return }
        let menuBarHeight = NSStatusBar.system.thickness
        // Sit flush against the bottom of the menu bar.
        let y = screen.frame.maxY - menuBarHeight - petSize
        let x = screen.frame.maxX - petSize - petInset - CGFloat(slotIndex) * (petSize + petGap)
        window.setFrame(
            NSRect(origin: NSPoint(x: x, y: y), size: CGSize(width: petSize, height: petSize)),
            display: false
        )
    }

    private func onPetSizeChanged() {
        contentView.frame = NSRect(origin: .zero, size: CGSize(width: petSize, height: petSize))
        contentView.layer?.frame = contentView.bounds
        applyScreenPosition()
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

        infoFadeTimer?.invalidate()
        infoFadeTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.infoWindow?.orderOut(nil)
            }
        }
    }

    private func identifyingText() -> String {
        var parts: [String] = []
        if let cwd = lastCwd, !cwd.isEmpty {
            parts.append((cwd as NSString).lastPathComponent)
        }
        if sessionId.count >= 8 {
            parts.append("session \(sessionId.prefix(8))")
        }
        return parts.isEmpty ? sessionId : parts.joined(separator: " — ")
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
/// current sprite frame, so transparent corners pass clicks through to
/// whatever is underneath.
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
