import AppKit
import CoreGraphics

/// Renders a pixel-art speech bubble as a CGImage.
///
/// The image is rendered at half size and displayed at 2× with nearest-neighbor
/// magnification so each "bubble pixel" matches the sprite's pixel density.
enum BubbleRenderer {
    /// Pixels-per-display-point scale factor: image pixel → screen point.
    static let displayScale: CGFloat = 2

    /// Returns (image, displaySize) where displaySize is the NSWindow size to use.
    static func render(text: String) -> (CGImage, CGSize)? {
        let font = NSFont(name: "Menlo", size: 7) ?? .monospacedSystemFont(ofSize: 7, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(red: 0.12, green: 0.08, blue: 0.05, alpha: 1),
        ]
        let measured = (text as NSString).size(withAttributes: attrs)

        let padX = 5, padY = 3, tailH = 4, border = 1
        let imgW = Int(measured.width.rounded(.up)) + padX * 2 + border * 2
        let imgH = Int(measured.height.rounded(.up)) + padY * 2 + tailH + border * 2

        guard let ctx = CGContext(
            data: nil, width: imgW, height: imgH,
            bitsPerComponent: 8, bytesPerRow: imgW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        ctx.setShouldSmoothFonts(false)

        let dark  = CGColor(red: 0.12, green: 0.08, blue: 0.05, alpha: 1)
        let cream = CGColor(red: 1.00, green: 0.97, blue: 0.88, alpha: 1)

        // Bubble body background
        ctx.setFillColor(cream)
        ctx.fill(CGRect(x: 0, y: tailH, width: imgW, height: imgH - tailH))

        // 1px border around bubble body
        ctx.setFillColor(dark)
        ctx.fill(CGRect(x: 0,         y: tailH,          width: imgW,    height: border))
        ctx.fill(CGRect(x: 0,         y: imgH - border,  width: imgW,    height: border))
        ctx.fill(CGRect(x: 0,         y: tailH,          width: border,  height: imgH - tailH))
        ctx.fill(CGRect(x: imgW - border, y: tailH,      width: border,  height: imgH - tailH))

        // Triangle tail centered at bottom, pointing down toward the pet
        let cx = imgW / 2
        for row in 0..<tailH {
            let half = tailH - row       // half-width at this row (tapers to 1 at tip)
            let rx = cx - half
            let rw = half * 2
            ctx.setFillColor(dark)
            ctx.fill(CGRect(x: rx, y: row, width: 1, height: 1))
            if rw > 1 {
                ctx.fill(CGRect(x: rx + rw - 1, y: row, width: 1, height: 1))
            }
            if rw > 2 {
                ctx.setFillColor(cream)
                ctx.fill(CGRect(x: rx + 1, y: row, width: rw - 2, height: 1))
            }
        }

        // Text
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx
        (text as NSString).draw(
            at: NSPoint(x: border + padX, y: tailH + border + padY),
            withAttributes: attrs
        )
        NSGraphicsContext.current = nil

        guard let image = ctx.makeImage() else { return nil }
        let displaySize = CGSize(
            width:  CGFloat(imgW) * displayScale,
            height: CGFloat(imgH) * displayScale
        )
        return (image, displaySize)
    }
}
