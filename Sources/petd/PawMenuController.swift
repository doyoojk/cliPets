import AppKit
import CoreGraphics

// MARK: - Controller

@MainActor
final class PawMenuController: NSObject {
    private let pawWindow: NSWindow
    private var panel: NSPanel?
    private weak var sessionCountField: NSTextField?

    var onToggleOverlays: (() -> Void)?
    var onQuit: (() -> Void)?
    var activeSessionCount: (() -> Int)?

    override init() {
        let size: CGFloat = 44
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.hasShadow = false
        pawWindow = w
        super.init()

        let view = PawView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.onSingleClick  = { [weak self] in self?.togglePanel() }
        view.onRightClick   = { [weak self] e in self?.showContextMenu(for: e) }
        view.onCmdClick     = { [weak self] in self?.onToggleOverlays?() }
        view.onDragged      = { [weak self] newOrigin in
            guard let self else { return }
            self.pawWindow.setFrameOrigin(newOrigin)
            UserDefaults.standard.set(
                [Double(newOrigin.x), Double(newOrigin.y)],
                forKey: "pawWindowOrigin"
            )
            if let p = self.panel, p.isVisible { self.positionPanel() }
        }
        w.contentView = view

        if let arr = UserDefaults.standard.array(forKey: "pawWindowOrigin") as? [Double],
           arr.count == 2 {
            w.setFrameOrigin(NSPoint(x: arr[0], y: arr[1]))
        } else if let screen = NSScreen.main {
            w.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - size - 24,
                y: screen.visibleFrame.maxY - size - 24
            ))
        }

        w.orderFront(nil)
    }

    // MARK: - Panel

    private func togglePanel() {
        if let p = panel, p.isVisible {
            p.orderOut(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        let p = ensurePanel()
        let count = activeSessionCount?() ?? 0
        sessionCountField?.stringValue = "\(count) active session\(count == 1 ? "" : "s")"
        positionPanel()
        p.orderFront(nil)
    }

    private func positionPanel() {
        guard let p = panel else { return }
        let pf = pawWindow.frame
        let ps = p.frame.size
        var x = pf.minX - ps.width - 8
        if x < 8 { x = pf.maxX + 8 }
        let y = max(8, pf.maxY - ps.height)
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }

        let w: CGFloat = 210, h: CGFloat = 158
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "cliPets"
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        let countLabel = NSTextField(labelWithString: "0 active sessions")
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .center
        countLabel.frame = NSRect(x: 0, y: h - 38, width: w, height: 18)
        content.addSubview(countLabel)
        sessionCountField = countLabel

        let sep = NSBox(); sep.boxType = .separator
        sep.frame = NSRect(x: 0, y: h - 50, width: w, height: 1)
        content.addSubview(sep)

        let toggleBtn = makeButton("Toggle all pets", action: #selector(handleToggle), y: 88, width: w)
        content.addSubview(toggleBtn)

        let sep2 = NSBox(); sep2.boxType = .separator
        sep2.frame = NSRect(x: 12, y: 74, width: w - 24, height: 1)
        content.addSubview(sep2)

        // Placeholder for collection grid (Phase 7)
        let collectionLabel = NSTextField(labelWithString: "Collection coming in Phase 7")
        collectionLabel.font = .systemFont(ofSize: 10)
        collectionLabel.textColor = .tertiaryLabelColor
        collectionLabel.alignment = .center
        collectionLabel.frame = NSRect(x: 0, y: 50, width: w, height: 16)
        content.addSubview(collectionLabel)

        let sep3 = NSBox(); sep3.boxType = .separator
        sep3.frame = NSRect(x: 12, y: 44, width: w - 24, height: 1)
        content.addSubview(sep3)

        let quitBtn = makeButton("Quit cliPets", action: #selector(handleQuit), y: 12, width: w)
        content.addSubview(quitBtn)

        p.contentView = content
        panel = p
        return p
    }

    private func makeButton(_ title: String, action: Selector, y: CGFloat, width: CGFloat) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.frame = NSRect(x: 12, y: y, width: width - 24, height: 26)
        return btn
    }

    // MARK: - Actions

    @objc private func handleToggle() {
        onToggleOverlays?()
    }

    @objc private func handleQuit() {
        onQuit?()
    }

    private func showContextMenu(for event: NSEvent) {
        let menu = NSMenu()
        let t = NSMenuItem(title: "Toggle all pets", action: #selector(handleToggle), keyEquivalent: "")
        t.target = self
        menu.addItem(t)
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit cliPets", action: #selector(handleQuit), keyEquivalent: "")
        q.target = self
        menu.addItem(q)
        NSMenu.popUpContextMenu(menu, with: event, for: pawWindow.contentView!)
    }
}

// MARK: - Draggable paw view

private final class PawView: NSView {
    var onSingleClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onCmdClick: (() -> Void)?
    var onDragged: ((NSPoint) -> Void)?

    private var mouseDownLoc: NSPoint?
    private var windowOriginAtDown: NSPoint?

    private static let pawImage: NSImage? = {
        let devPath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Code/cliPets/Resources/PawIcon.png")
        if let img = NSImage(contentsOf: devPath) { return img }
        return Bundle.main.image(forResource: "PawIcon")
    }()

    override func draw(_ dirtyRect: NSRect) {
        guard let img = Self.pawImage else { return }
        img.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { onCmdClick?(); return }
        mouseDownLoc = event.locationInWindow
        windowOriginAtDown = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLoc, let origin = windowOriginAtDown else { return }
        let d = NSPoint(x: event.locationInWindow.x - start.x, y: event.locationInWindow.y - start.y)
        onDragged?(NSPoint(x: origin.x + d.x, y: origin.y + d.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = mouseDownLoc else { return }
        defer { mouseDownLoc = nil; windowOriginAtDown = nil }
        let loc = event.locationInWindow
        let dist = hypot(loc.x - start.x, loc.y - start.y)
        if dist < 3 { onSingleClick?() }
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
