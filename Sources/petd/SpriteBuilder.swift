import CoreGraphics

/// Animation state that drives a pet's current sprite sequence.
enum PetAnimationState: Hashable {
    case idle
    case listening
    case working
    case writing
    case celebrate
    case alert

    /// Higher priority states override lower ones. One-shot states (celebrate,
    /// alert) are never interrupted by lower-priority triggers.
    var priority: Int {
        switch self {
        case .idle:              return 0
        case .listening:         return 1
        case .working, .writing: return 2
        case .celebrate, .alert: return 3
        }
    }

    var isOneShot: Bool {
        switch self {
        case .celebrate, .alert: return true
        default:                 return false
        }
    }

    var bubbleText: String? {
        switch self {
        case .celebrate: return "done! ✨"
        case .alert:     return "hey!"
        case .working:   return "running…"
        case .writing:   return "writing…"
        default:         return nil
        }
    }
}

enum SpriteBuilder {
    /// Builds the complete sprite dictionary for the given color palette.
    static func allSprites(palette: PetPalette) -> [PetAnimationState: [CGImage]] {
        [
            .idle:      [frame(.idle,      palette: palette), frame(.idleBlink, palette: palette)],
            .listening: [frame(.idle,      palette: palette), frame(.idleBlink, palette: palette)],
            .working:   [frame(.writeA,    palette: palette), frame(.writeB,    palette: palette)],
            .writing:   [frame(.writeA,    palette: palette), frame(.writeB,    palette: palette)],
            .celebrate: [frame(.celebA,    palette: palette), frame(.celebB,    palette: palette),
                         frame(.celebC,    palette: palette), frame(.celebD,    palette: palette)],
            .alert:     [frame(.alertA,    palette: palette), frame(.alertB,    palette: palette),
                         frame(.alertC,    palette: palette)],
        ]
    }

    // MARK: - Frame identifiers

    private enum Frame {
        case idle, idleBlink
        case listenA, listenB
        case workA, workB, workC
        case writeA, writeB
        case celebA, celebB, celebC, celebD
        case alertA, alertB, alertC
    }

    private static func frame(_ f: Frame, palette: PetPalette) -> CGImage {
        let size = 32
        let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.interpolationQuality = .none
        draw(f, in: ctx, palette: palette)
        return ctx.makeImage()!
    }

    // MARK: - Shared drawing helpers

    /// Draws the sitting cat body. All y values use bottom-left-origin CG coords.
    /// - yOff: shifts the entire body upward (jump frames).
    /// - earYOff: additional ear-only vertical offset relative to body.
    /// - squish: compresses body height and widens feet (landing frame).
    private static func drawBody(
        in ctx: CGContext,
        palette: PetPalette,
        yOff: Int = 0,
        earYOff: Int = 0,
        earWide: Bool = false,
        squish: Int = 0
    ) {
        ctx.setFillColor(palette.body)
        let ey = yOff + earYOff
        let ew = (earYOff > 0 || earWide) ? 1 : 0
        // Left ear — outer edge widens when perked/alert
        ctx.fill(CGRect(x: 6 - ew, y: 22 + ey, width: 4 + ew, height: 5))
        ctx.fill(CGRect(x: 7 - ew, y: 27 + ey, width: 2 + ew, height: 1))
        // Inner corner pixel — smooths the ear-to-head joint
        ctx.fill(CGRect(x: 10,     y: 24 + ey, width: 1,       height: 1))
        // Right ear — mirrored
        ctx.fill(CGRect(x: 22,     y: 22 + ey, width: 4 + ew,  height: 5))
        ctx.fill(CGRect(x: 23,     y: 27 + ey, width: 2 + ew,  height: 1))
        ctx.fill(CGRect(x: 21,     y: 24 + ey, width: 1,       height: 1))
        ctx.fill(CGRect(x: 5,  y: 8 + yOff,  width: 22, height: 16 - squish))
        ctx.fill(CGRect(x: 3,  y: 10 + yOff, width: 2,  height: 12 - squish))
        ctx.fill(CGRect(x: 27, y: 10 + yOff, width: 2,  height: 12 - squish))
        ctx.fill(CGRect(x: 7,  y: 6 + yOff,  width: 18, height: 2))
        ctx.fill(CGRect(x: 8 - squish, y: 4 + yOff, width: 4 + squish, height: 3))
        ctx.fill(CGRect(x: 20,          y: 4 + yOff, width: 4 + squish, height: 3))
        ctx.setFillColor(palette.bodyDark)
        ctx.fill(CGRect(x: 10, y: 7 + yOff, width: 12, height: 2))
    }

    private static func drawNose(in ctx: CGContext, palette: PetPalette, yOff: Int = 0) {
        ctx.setFillColor(palette.noseCol)
        ctx.fill(CGRect(x: 15, y: 12 + yOff, width: 2, height: 1))
    }

    private static func drawSidePaw(in ctx: CGContext, palette: PetPalette, side: Int, yOff: Int = 0) {
        ctx.setFillColor(palette.pawCol)
        let x = side == 0 ? 1 : 28
        ctx.fill(CGRect(x: x, y: 14 + yOff, width: 3, height: 3))
        ctx.fill(CGRect(x: x, y: 17 + yOff, width: 2, height: 1))
    }

    private static func drawForwardPaws(in ctx: CGContext, palette: PetPalette, yOff: Int = 0, raised: Int = 0) {
        ctx.setFillColor(palette.pawCol)
        ctx.fill(CGRect(x: 7,  y: 4 + yOff,         width: 6, height: 4))
        ctx.fill(CGRect(x: 19, y: 4 + yOff + raised, width: 6, height: 4))
    }

    // Confetti: 5 tiny 2×1 flecks scattered around the cat, cycling positions each frame.
    private static let confettiColors = [
        CGColor(red: 1.00, green: 0.85, blue: 0.10, alpha: 1),  // yellow
        CGColor(red: 0.30, green: 0.85, blue: 0.40, alpha: 1),  // green
        CGColor(red: 1.00, green: 0.40, blue: 0.70, alpha: 1),  // pink
        CGColor(red: 0.30, green: 0.65, blue: 1.00, alpha: 1),  // blue
        CGColor(red: 1.00, green: 0.55, blue: 0.20, alpha: 1),  // orange
    ]
    // Each frame gets a different scatter pattern so flecks appear to fall/spin.
    private static let confettiSets: [[(x: Int, y: Int, c: Int)]] = [
        [(3, 29, 0), (13, 30, 1), (22, 28, 2), (28, 30, 3), (7, 27, 4)],
        [(5, 30, 1), (16, 28, 2), (25, 31, 3), (1, 29, 4), (19, 27, 0)],
        [(8, 28, 2), (11, 31, 3), (24, 29, 4), (4, 30, 0), (27, 27, 1)],
        [(2, 29, 3), (14, 27, 4), (21, 30, 0), (29, 28, 1), (9, 31, 2)],
    ]
    private static func drawConfetti(in ctx: CGContext, set: Int, yOff: Int = 0) {
        for piece in confettiSets[set % confettiSets.count] {
            ctx.setFillColor(confettiColors[piece.c])
            ctx.fill(CGRect(x: piece.x, y: piece.y + yOff, width: 2, height: 1))
        }
    }

    // MARK: - Per-frame drawing

    private static func draw(_ f: Frame, in ctx: CGContext, palette: PetPalette) {
        switch f {

        // ── idle ────────────────────────────────────────────────────────────
        case .idle:
            drawBody(in: ctx, palette: palette)
            ctx.setFillColor(palette.eyeCol)
            ctx.fill(CGRect(x: 10, y: 14, width: 3, height: 3))
            ctx.fill(CGRect(x: 19, y: 14, width: 3, height: 3))
            ctx.setFillColor(palette.white)
            ctx.fill(CGRect(x: 11, y: 16, width: 1, height: 1))
            ctx.fill(CGRect(x: 20, y: 16, width: 1, height: 1))
            drawNose(in: ctx, palette: palette)

        case .idleBlink:
            drawBody(in: ctx, palette: palette)
            ctx.setFillColor(palette.eyeDim)
            ctx.fill(CGRect(x: 10, y: 15, width: 3, height: 1))
            ctx.fill(CGRect(x: 19, y: 15, width: 3, height: 1))
            drawNose(in: ctx, palette: palette)

        // ── listening ───────────────────────────────────────────────────────
        case .listenA:
            drawBody(in: ctx, palette: palette)
            ctx.setFillColor(palette.eyeCol)
            ctx.fill(CGRect(x: 10, y: 14, width: 3, height: 2))
            ctx.fill(CGRect(x: 19, y: 14, width: 3, height: 2))
            ctx.setFillColor(palette.eyeDim)
            ctx.fill(CGRect(x: 10, y: 15, width: 3, height: 1))
            ctx.fill(CGRect(x: 19, y: 15, width: 3, height: 1))
            drawNose(in: ctx, palette: palette)

        case .listenB:
            drawBody(in: ctx, palette: palette)
            ctx.setFillColor(palette.eyeDim)
            ctx.fill(CGRect(x: 10, y: 15, width: 3, height: 1))
            ctx.fill(CGRect(x: 19, y: 15, width: 3, height: 1))
            drawNose(in: ctx, palette: palette)

        // ── working ─────────────────────────────────────────────────────────
        // Ears perked (wider+taller), alert eyes (3×4, same x as idle), typing paws.
        case .workA:
            drawBody(in: ctx, palette: palette, earYOff: 2)
            ctx.setFillColor(palette.eyeCol)
            ctx.fill(CGRect(x: 10, y: 13, width: 3, height: 4))
            ctx.fill(CGRect(x: 19, y: 13, width: 3, height: 4))
            ctx.setFillColor(palette.white)
            ctx.fill(CGRect(x: 11, y: 15, width: 1, height: 1))
            ctx.fill(CGRect(x: 20, y: 15, width: 1, height: 1))
            drawNose(in: ctx, palette: palette)
            drawForwardPaws(in: ctx, palette: palette, raised: 0)

        case .workB:
            drawBody(in: ctx, palette: palette, earYOff: 2)
            ctx.setFillColor(palette.eyeCol)
            ctx.fill(CGRect(x: 10, y: 13, width: 3, height: 4))
            ctx.fill(CGRect(x: 19, y: 13, width: 3, height: 4))
            ctx.setFillColor(palette.white)
            ctx.fill(CGRect(x: 11, y: 15, width: 1, height: 1))
            ctx.fill(CGRect(x: 20, y: 15, width: 1, height: 1))
            drawNose(in: ctx, palette: palette)
            drawForwardPaws(in: ctx, palette: palette, raised: 1)

        case .workC:
            drawBody(in: ctx, palette: palette, earYOff: 2)
            ctx.setFillColor(palette.eyeCol)
            ctx.fill(CGRect(x: 10, y: 13, width: 3, height: 4))
            ctx.fill(CGRect(x: 19, y: 13, width: 3, height: 4))
            ctx.setFillColor(palette.white)
            ctx.fill(CGRect(x: 11, y: 15, width: 1, height: 1))
            ctx.fill(CGRect(x: 20, y: 15, width: 1, height: 1))
            drawNose(in: ctx, palette: palette)
            drawForwardPaws(in: ctx, palette: palette, raised: -1)

        // ── writing ─────────────────────────────────────────────────────────
        case .writeA:
            drawBody(in: ctx, palette: palette)
            ctx.setFillColor(palette.eyeCol)
            ctx.fill(CGRect(x: 10, y: 15, width: 3, height: 1))
            ctx.fill(CGRect(x: 19, y: 15, width: 3, height: 1))
            drawNose(in: ctx, palette: palette)
            drawForwardPaws(in: ctx, palette: palette, raised: 0)

        case .writeB:
            drawBody(in: ctx, palette: palette)
            ctx.setFillColor(palette.eyeCol)
            ctx.fill(CGRect(x: 10, y: 15, width: 3, height: 1))
            ctx.fill(CGRect(x: 19, y: 15, width: 3, height: 1))
            drawNose(in: ctx, palette: palette)
            drawForwardPaws(in: ctx, palette: palette, raised: 1)

        // ── celebrate ───────────────────────────────────────────────────────
        // Gentle bob up and down with confetti — no side paws.
        case .celebA:
            drawBody(in: ctx, palette: palette)
            ctx.setFillColor(palette.eyeCol)
            ctx.fill(CGRect(x: 10, y: 14, width: 3, height: 3))
            ctx.fill(CGRect(x: 19, y: 14, width: 3, height: 3))
            ctx.setFillColor(palette.white)
            ctx.fill(CGRect(x: 11, y: 16, width: 1, height: 1))
            ctx.fill(CGRect(x: 20, y: 16, width: 1, height: 1))
            drawNose(in: ctx, palette: palette)
            drawForwardPaws(in: ctx, palette: palette)
            drawConfetti(in: ctx, set: 0)

        case .celebB:
            drawBody(in: ctx, palette: palette, yOff: 3)
            ctx.setFillColor(palette.eyeCol)
            ctx.fill(CGRect(x: 10, y: 17, width: 3, height: 3))
            ctx.fill(CGRect(x: 19, y: 17, width: 3, height: 3))
            ctx.setFillColor(palette.white)
            ctx.fill(CGRect(x: 11, y: 19, width: 1, height: 1))
            ctx.fill(CGRect(x: 20, y: 19, width: 1, height: 1))
            drawNose(in: ctx, palette: palette, yOff: 3)
            drawForwardPaws(in: ctx, palette: palette, yOff: 3)
            drawConfetti(in: ctx, set: 1)

        case .celebC:
            drawBody(in: ctx, palette: palette, yOff: 5)
            ctx.setFillColor(palette.eyeCol)
            ctx.fill(CGRect(x: 10, y: 19, width: 3, height: 3))
            ctx.fill(CGRect(x: 19, y: 19, width: 3, height: 3))
            ctx.setFillColor(palette.white)
            ctx.fill(CGRect(x: 11, y: 21, width: 1, height: 1))
            ctx.fill(CGRect(x: 20, y: 21, width: 1, height: 1))
            drawNose(in: ctx, palette: palette, yOff: 5)
            drawForwardPaws(in: ctx, palette: palette, yOff: 5)
            drawConfetti(in: ctx, set: 2)

        case .celebD:
            drawBody(in: ctx, palette: palette, yOff: 2)
            ctx.setFillColor(palette.eyeCol)
            ctx.fill(CGRect(x: 10, y: 16, width: 3, height: 3))
            ctx.fill(CGRect(x: 19, y: 16, width: 3, height: 3))
            ctx.setFillColor(palette.white)
            ctx.fill(CGRect(x: 11, y: 18, width: 1, height: 1))
            ctx.fill(CGRect(x: 20, y: 18, width: 1, height: 1))
            drawNose(in: ctx, palette: palette, yOff: 2)
            drawForwardPaws(in: ctx, palette: palette, yOff: 2)
            drawConfetti(in: ctx, set: 3)

        // ── alert ───────────────────────────────────────────────────────────
        // Bigger eyes (4×4, one step up from normal 3×3) + perked ears. No hop.
        case .alertA:
            // Ears widen (no vertical shift) — first beat of surprise.
            drawBody(in: ctx, palette: palette, earWide: false)
            ctx.setFillColor(palette.eyeCol)
            ctx.fill(CGRect(x: 10, y: 13, width: 3, height: 4))
            ctx.fill(CGRect(x: 19, y: 13, width: 3, height: 4))
            ctx.setFillColor(palette.white)
            ctx.fill(CGRect(x: 11, y: 15, width: 1, height: 1))
            ctx.fill(CGRect(x: 20, y: 15, width: 1, height: 1))
            drawNose(in: ctx, palette: palette)

        case .alertB:
            // Ears at widest — peak of surprise.
            drawBody(in: ctx, palette: palette, earWide: true)
            ctx.setFillColor(palette.eyeCol)
            ctx.fill(CGRect(x: 10, y: 13, width: 3, height: 4))
            ctx.fill(CGRect(x: 19, y: 13, width: 3, height: 4))
            ctx.setFillColor(palette.white)
            ctx.fill(CGRect(x: 11, y: 15, width: 1, height: 1))
            ctx.fill(CGRect(x: 20, y: 15, width: 1, height: 1))
            drawNose(in: ctx, palette: palette)

        case .alertC:
            // Settling back — ears back to normal width.
            drawBody(in: ctx, palette: palette, earWide: false)
            ctx.setFillColor(palette.eyeCol)
            ctx.fill(CGRect(x: 10, y: 13, width: 3, height: 4))
            ctx.fill(CGRect(x: 19, y: 13, width: 3, height: 4))
            ctx.setFillColor(palette.white)
            ctx.fill(CGRect(x: 11, y: 15, width: 1, height: 1))
            ctx.fill(CGRect(x: 20, y: 15, width: 1, height: 1))
            drawNose(in: ctx, palette: palette)
        }
    }
}
