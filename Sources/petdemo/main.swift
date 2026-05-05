import AppKit
import CoreGraphics

// ── Palette ──────────────────────────────────────────────────────────────────

struct PetPalette {
    let body:     CGColor
    let bodyDark: CGColor
    let eyeCol:   CGColor
    let eyeDim:   CGColor
    let noseCol:  CGColor
    let pawCol:   CGColor
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
}

struct Variant {
    let name:    String
    let palette: PetPalette
}

let variants: [Variant] = [
    Variant(name: "Orange", palette: PetPalette(
        body:     CGColor(red: 0.96, green: 0.60, blue: 0.26, alpha: 1),
        bodyDark: CGColor(red: 0.78, green: 0.44, blue: 0.18, alpha: 1),
        eyeCol:   CGColor(red: 0.10, green: 0.08, blue: 0.05, alpha: 1),
        eyeDim:   CGColor(red: 0.35, green: 0.20, blue: 0.10, alpha: 1),
        noseCol:  CGColor(red: 0.90, green: 0.40, blue: 0.50, alpha: 1),
        pawCol:   CGColor(red: 0.88, green: 0.52, blue: 0.18, alpha: 1)
    )),
    Variant(name: "Gray", palette: PetPalette(
        body:     CGColor(red: 0.70, green: 0.70, blue: 0.72, alpha: 1),
        bodyDark: CGColor(red: 0.50, green: 0.50, blue: 0.52, alpha: 1),
        eyeCol:   CGColor(red: 0.10, green: 0.20, blue: 0.35, alpha: 1),
        eyeDim:   CGColor(red: 0.30, green: 0.40, blue: 0.55, alpha: 1),
        noseCol:  CGColor(red: 0.85, green: 0.50, blue: 0.60, alpha: 1),
        pawCol:   CGColor(red: 0.60, green: 0.60, blue: 0.62, alpha: 1)
    )),
    Variant(name: "White", palette: PetPalette(
        body:     CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1),
        bodyDark: CGColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1),
        eyeCol:   CGColor(red: 0.10, green: 0.55, blue: 0.10, alpha: 1),
        eyeDim:   CGColor(red: 0.25, green: 0.60, blue: 0.25, alpha: 1),
        noseCol:  CGColor(red: 0.90, green: 0.45, blue: 0.55, alpha: 1),
        pawCol:   CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1)
    )),
    Variant(name: "Black", palette: PetPalette(
        body:     CGColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1),
        bodyDark: CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1),
        eyeCol:   CGColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1),
        eyeDim:   CGColor(red: 0.30, green: 0.55, blue: 0.90, alpha: 1),
        noseCol:  CGColor(red: 0.80, green: 0.35, blue: 0.50, alpha: 1),
        pawCol:   CGColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1)
    )),
    Variant(name: "Tabby", palette: PetPalette(
        body:     CGColor(red: 0.80, green: 0.58, blue: 0.35, alpha: 1),
        bodyDark: CGColor(red: 0.50, green: 0.30, blue: 0.10, alpha: 1),
        eyeCol:   CGColor(red: 0.10, green: 0.50, blue: 0.15, alpha: 1),
        eyeDim:   CGColor(red: 0.20, green: 0.60, blue: 0.25, alpha: 1),
        noseCol:  CGColor(red: 0.88, green: 0.42, blue: 0.52, alpha: 1),
        pawCol:   CGColor(red: 0.70, green: 0.48, blue: 0.28, alpha: 1)
    )),
    Variant(name: "Cream", palette: PetPalette(
        body:     CGColor(red: 0.98, green: 0.88, blue: 0.70, alpha: 1),
        bodyDark: CGColor(red: 0.85, green: 0.72, blue: 0.50, alpha: 1),
        eyeCol:   CGColor(red: 0.55, green: 0.28, blue: 0.10, alpha: 1),
        eyeDim:   CGColor(red: 0.70, green: 0.42, blue: 0.22, alpha: 1),
        noseCol:  CGColor(red: 0.92, green: 0.50, blue: 0.55, alpha: 1),
        pawCol:   CGColor(red: 0.90, green: 0.78, blue: 0.58, alpha: 1)
    )),
    Variant(name: "Cosmic ★", palette: PetPalette(
        body:     CGColor(red: 0.35, green: 0.18, blue: 0.55, alpha: 1),
        bodyDark: CGColor(red: 0.20, green: 0.08, blue: 0.38, alpha: 1),
        eyeCol:   CGColor(red: 0.80, green: 0.50, blue: 1.00, alpha: 1),
        eyeDim:   CGColor(red: 0.60, green: 0.30, blue: 0.80, alpha: 1),
        noseCol:  CGColor(red: 0.90, green: 0.40, blue: 0.80, alpha: 1),
        pawCol:   CGColor(red: 0.28, green: 0.12, blue: 0.48, alpha: 1)
    )),
    Variant(name: "Golden ★", palette: PetPalette(
        body:     CGColor(red: 0.95, green: 0.80, blue: 0.20, alpha: 1),
        bodyDark: CGColor(red: 0.78, green: 0.60, blue: 0.08, alpha: 1),
        eyeCol:   CGColor(red: 0.65, green: 0.38, blue: 0.08, alpha: 1),
        eyeDim:   CGColor(red: 0.80, green: 0.55, blue: 0.20, alpha: 1),
        noseCol:  CGColor(red: 0.90, green: 0.45, blue: 0.45, alpha: 1),
        pawCol:   CGColor(red: 0.88, green: 0.72, blue: 0.15, alpha: 1)
    )),
    Variant(name: "Rainbow ✦", palette: PetPalette(
        body:     CGColor(red: 0.98, green: 0.65, blue: 0.80, alpha: 1),
        bodyDark: CGColor(red: 0.85, green: 0.45, blue: 0.65, alpha: 1),
        eyeCol:   CGColor(red: 0.10, green: 0.80, blue: 0.85, alpha: 1),
        eyeDim:   CGColor(red: 0.20, green: 0.65, blue: 0.70, alpha: 1),
        noseCol:  CGColor(red: 0.35, green: 0.80, blue: 0.40, alpha: 1),
        pawCol:   CGColor(red: 0.92, green: 0.55, blue: 0.72, alpha: 1)
    )),
]

// ── Sprite rendering (same logic as SpriteBuilder) ────────────────────────────

func makeSprite(palette: PetPalette) -> CGImage {
    let size = 32
    let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .none

    let p = palette
    // Body
    ctx.setFillColor(p.body)
    let ew = 0
    ctx.fill(CGRect(x: 6 - ew, y: 22, width: 4 + ew, height: 5))
    ctx.fill(CGRect(x: 7 - ew, y: 27, width: 2 + ew, height: 1))
    ctx.fill(CGRect(x: 10,     y: 24, width: 1,       height: 1))
    ctx.fill(CGRect(x: 22,     y: 22, width: 4 + ew,  height: 5))
    ctx.fill(CGRect(x: 23,     y: 27, width: 2 + ew,  height: 1))
    ctx.fill(CGRect(x: 21,     y: 24, width: 1,       height: 1))
    ctx.fill(CGRect(x: 5,  y: 8,  width: 22, height: 16))
    ctx.fill(CGRect(x: 3,  y: 10, width: 2,  height: 12))
    ctx.fill(CGRect(x: 27, y: 10, width: 2,  height: 12))
    ctx.fill(CGRect(x: 7,  y: 6,  width: 18, height: 2))
    ctx.fill(CGRect(x: 8,  y: 4,  width: 4,  height: 3))
    ctx.fill(CGRect(x: 20, y: 4,  width: 4,  height: 3))
    ctx.setFillColor(p.bodyDark)
    ctx.fill(CGRect(x: 10, y: 7, width: 12, height: 2))
    // Eyes
    ctx.setFillColor(p.eyeCol)
    ctx.fill(CGRect(x: 10, y: 14, width: 3, height: 3))
    ctx.fill(CGRect(x: 19, y: 14, width: 3, height: 3))
    ctx.setFillColor(p.white)
    ctx.fill(CGRect(x: 11, y: 16, width: 1, height: 1))
    ctx.fill(CGRect(x: 20, y: 16, width: 1, height: 1))
    // Nose
    ctx.setFillColor(p.noseCol)
    ctx.fill(CGRect(x: 15, y: 12, width: 2, height: 1))
    // Paws
    ctx.setFillColor(p.pawCol)
    ctx.fill(CGRect(x: 7,  y: 4, width: 6, height: 4))
    ctx.fill(CGRect(x: 19, y: 4, width: 6, height: 4))

    return ctx.makeImage()!
}

// ── App ───────────────────────────────────────────────────────────────────────

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let scale:   CGFloat = 5      // each pixel → 5 display pts
let sprite:  CGFloat = 32 * scale
let padX:    CGFloat = 24
let padY:    CGFloat = 36
let labelH:  CGFloat = 18
let cols     = 3
let rows     = Int(ceil(Double(variants.count) / Double(cols)))
let winW     = padX * 2 + CGFloat(cols) * sprite + CGFloat(cols - 1) * padX
let winH     = padY + CGFloat(rows) * (sprite + labelH + 12) + padY

let win = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
win.title = "cliPets — All Variants"
win.center()

let contentView = NSView(frame: win.contentView!.bounds)
contentView.wantsLayer = true
contentView.layer?.backgroundColor = CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)

for (i, variant) in variants.enumerated() {
    let col = i % cols
    let row = rows - 1 - (i / cols)   // bottom-left origin: flip row
    let cellX = padX + CGFloat(col) * (sprite + padX)
    let cellY = padY + CGFloat(row) * (sprite + labelH + 12)

    // Sprite
    let img = makeSprite(palette: variant.palette)
    let imgView = NSImageView(frame: NSRect(x: cellX, y: cellY + labelH + 4, width: sprite, height: sprite))
    let nsImg = NSImage(cgImage: img, size: NSSize(width: sprite, height: sprite))
    imgView.image = nsImg
    imgView.imageScaling = .scaleAxesIndependently
    imgView.layer?.magnificationFilter = .nearest
    imgView.wantsLayer = true
    imgView.layer?.magnificationFilter = .nearest
    contentView.addSubview(imgView)

    // Label
    let label = NSTextField(labelWithString: variant.name)
    label.frame = NSRect(x: cellX, y: cellY, width: sprite, height: labelH)
    label.alignment = .center
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = .white
    contentView.addSubview(label)
}

win.contentView = contentView
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

win.windowController?.shouldCascadeWindows = false

// Close when window closes.
class D: NSObject, NSWindowDelegate {
    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }
}
let d = D()
win.delegate = d

app.run()
