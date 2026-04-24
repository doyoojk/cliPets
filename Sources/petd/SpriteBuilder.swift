import CoreGraphics

enum CatState {
    case idle
    case blink
}

enum SpriteBuilder {
    /// Procedural 32x32 placeholder cat sprite. Replaced in Phase 7 by real sprite sheets.
    static func makeCat(state: CatState) -> CGImage {
        let size = 32
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        ctx.interpolationQuality = .none

        let body = CGColor(red: 0.96, green: 0.60, blue: 0.26, alpha: 1)
        let bodyDark = CGColor(red: 0.78, green: 0.44, blue: 0.18, alpha: 1)
        let eyeOpen = CGColor(red: 0.10, green: 0.08, blue: 0.05, alpha: 1)
        let eyeClosed = CGColor(red: 0.35, green: 0.20, blue: 0.10, alpha: 1)
        let catchlight = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let nose = CGColor(red: 0.90, green: 0.40, blue: 0.50, alpha: 1)

        // Origin is bottom-left. Draw a sitting-cat loaf.
        // Ears
        ctx.setFillColor(body)
        ctx.fill(CGRect(x: 6, y: 22, width: 4, height: 5))
        ctx.fill(CGRect(x: 7, y: 27, width: 2, height: 1))
        ctx.fill(CGRect(x: 22, y: 22, width: 4, height: 5))
        ctx.fill(CGRect(x: 23, y: 27, width: 2, height: 1))

        // Head / body
        ctx.fill(CGRect(x: 5, y: 8, width: 22, height: 16))
        ctx.fill(CGRect(x: 3, y: 10, width: 2, height: 12))
        ctx.fill(CGRect(x: 27, y: 10, width: 2, height: 12))
        ctx.fill(CGRect(x: 7, y: 6, width: 18, height: 2))

        // Feet
        ctx.fill(CGRect(x: 8, y: 4, width: 4, height: 3))
        ctx.fill(CGRect(x: 20, y: 4, width: 4, height: 3))

        // Belly shadow
        ctx.setFillColor(bodyDark)
        ctx.fill(CGRect(x: 10, y: 7, width: 12, height: 2))

        // Eyes
        switch state {
        case .idle:
            ctx.setFillColor(eyeOpen)
            ctx.fill(CGRect(x: 10, y: 14, width: 3, height: 3))
            ctx.fill(CGRect(x: 19, y: 14, width: 3, height: 3))
            ctx.setFillColor(catchlight)
            ctx.fill(CGRect(x: 11, y: 16, width: 1, height: 1))
            ctx.fill(CGRect(x: 20, y: 16, width: 1, height: 1))
        case .blink:
            ctx.setFillColor(eyeClosed)
            ctx.fill(CGRect(x: 10, y: 15, width: 3, height: 1))
            ctx.fill(CGRect(x: 19, y: 15, width: 3, height: 1))
        }

        // Nose
        ctx.setFillColor(nose)
        ctx.fill(CGRect(x: 15, y: 12, width: 2, height: 1))

        return ctx.makeImage()!
    }
}
