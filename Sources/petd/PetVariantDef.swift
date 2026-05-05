import CoreGraphics

// MARK: - Rarity

enum RarityTier: String, CaseIterable {
    case common, uncommon, rare, mythic

    var weight: Double {
        switch self {
        case .common:   return 70
        case .uncommon: return 22
        case .rare:     return 7
        case .mythic:   return 1
        }
    }
}

// MARK: - Palette

struct PetPalette {
    let body:     CGColor
    let bodyDark: CGColor
    let eyeCol:   CGColor
    let eyeDim:   CGColor
    let noseCol:  CGColor
    let pawCol:   CGColor
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
}

// MARK: - Variant definition

struct PetVariantDef {
    let id:      String
    let name:    String
    let rarity:  RarityTier
    let palette: PetPalette
}

// MARK: - Catalog

enum PetCatalog {
    static let all: [PetVariantDef] = [
        // Common
        PetVariantDef(id: "cat_orange", name: "Orange Cat", rarity: .common, palette: PetPalette(
            body:     CGColor(red: 0.96, green: 0.60, blue: 0.26, alpha: 1),
            bodyDark: CGColor(red: 0.78, green: 0.44, blue: 0.18, alpha: 1),
            eyeCol:   CGColor(red: 0.10, green: 0.08, blue: 0.05, alpha: 1),
            eyeDim:   CGColor(red: 0.35, green: 0.20, blue: 0.10, alpha: 1),
            noseCol:  CGColor(red: 0.90, green: 0.40, blue: 0.50, alpha: 1),
            pawCol:   CGColor(red: 0.88, green: 0.52, blue: 0.18, alpha: 1)
        )),
        PetVariantDef(id: "cat_gray", name: "Gray Cat", rarity: .common, palette: PetPalette(
            body:     CGColor(red: 0.70, green: 0.70, blue: 0.72, alpha: 1),
            bodyDark: CGColor(red: 0.50, green: 0.50, blue: 0.52, alpha: 1),
            eyeCol:   CGColor(red: 0.10, green: 0.20, blue: 0.35, alpha: 1),
            eyeDim:   CGColor(red: 0.30, green: 0.40, blue: 0.55, alpha: 1),
            noseCol:  CGColor(red: 0.85, green: 0.50, blue: 0.60, alpha: 1),
            pawCol:   CGColor(red: 0.60, green: 0.60, blue: 0.62, alpha: 1)
        )),
        PetVariantDef(id: "cat_white", name: "White Cat", rarity: .common, palette: PetPalette(
            body:     CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1),
            bodyDark: CGColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1),
            eyeCol:   CGColor(red: 0.10, green: 0.55, blue: 0.10, alpha: 1),
            eyeDim:   CGColor(red: 0.25, green: 0.60, blue: 0.25, alpha: 1),
            noseCol:  CGColor(red: 0.90, green: 0.45, blue: 0.55, alpha: 1),
            pawCol:   CGColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1)
        )),
        // Uncommon
        PetVariantDef(id: "cat_black", name: "Black Cat", rarity: .uncommon, palette: PetPalette(
            body:     CGColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1),
            bodyDark: CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1),
            eyeCol:   CGColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1),
            eyeDim:   CGColor(red: 0.30, green: 0.55, blue: 0.90, alpha: 1),
            noseCol:  CGColor(red: 0.80, green: 0.35, blue: 0.50, alpha: 1),
            pawCol:   CGColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1)
        )),
        PetVariantDef(id: "cat_tabby", name: "Tabby Cat", rarity: .uncommon, palette: PetPalette(
            body:     CGColor(red: 0.80, green: 0.58, blue: 0.35, alpha: 1),
            bodyDark: CGColor(red: 0.50, green: 0.30, blue: 0.10, alpha: 1),
            eyeCol:   CGColor(red: 0.10, green: 0.50, blue: 0.15, alpha: 1),
            eyeDim:   CGColor(red: 0.20, green: 0.60, blue: 0.25, alpha: 1),
            noseCol:  CGColor(red: 0.88, green: 0.42, blue: 0.52, alpha: 1),
            pawCol:   CGColor(red: 0.70, green: 0.48, blue: 0.28, alpha: 1)
        )),
        PetVariantDef(id: "cat_cream", name: "Cream Cat", rarity: .uncommon, palette: PetPalette(
            body:     CGColor(red: 0.98, green: 0.88, blue: 0.70, alpha: 1),
            bodyDark: CGColor(red: 0.85, green: 0.72, blue: 0.50, alpha: 1),
            eyeCol:   CGColor(red: 0.55, green: 0.28, blue: 0.10, alpha: 1),
            eyeDim:   CGColor(red: 0.70, green: 0.42, blue: 0.22, alpha: 1),
            noseCol:  CGColor(red: 0.92, green: 0.50, blue: 0.55, alpha: 1),
            pawCol:   CGColor(red: 0.90, green: 0.78, blue: 0.58, alpha: 1)
        )),
        // Rare
        PetVariantDef(id: "cat_cosmic", name: "Cosmic Cat", rarity: .rare, palette: PetPalette(
            body:     CGColor(red: 0.35, green: 0.18, blue: 0.55, alpha: 1),
            bodyDark: CGColor(red: 0.20, green: 0.08, blue: 0.38, alpha: 1),
            eyeCol:   CGColor(red: 0.80, green: 0.50, blue: 1.00, alpha: 1),
            eyeDim:   CGColor(red: 0.60, green: 0.30, blue: 0.80, alpha: 1),
            noseCol:  CGColor(red: 0.90, green: 0.40, blue: 0.80, alpha: 1),
            pawCol:   CGColor(red: 0.28, green: 0.12, blue: 0.48, alpha: 1)
        )),
        PetVariantDef(id: "cat_golden", name: "Golden Cat", rarity: .rare, palette: PetPalette(
            body:     CGColor(red: 0.95, green: 0.80, blue: 0.20, alpha: 1),
            bodyDark: CGColor(red: 0.78, green: 0.60, blue: 0.08, alpha: 1),
            eyeCol:   CGColor(red: 0.65, green: 0.38, blue: 0.08, alpha: 1),
            eyeDim:   CGColor(red: 0.80, green: 0.55, blue: 0.20, alpha: 1),
            noseCol:  CGColor(red: 0.90, green: 0.45, blue: 0.45, alpha: 1),
            pawCol:   CGColor(red: 0.88, green: 0.72, blue: 0.15, alpha: 1)
        )),
        // Mythic
        PetVariantDef(id: "cat_rainbow", name: "Rainbow Cat", rarity: .mythic, palette: PetPalette(
            body:     CGColor(red: 0.98, green: 0.65, blue: 0.80, alpha: 1),
            bodyDark: CGColor(red: 0.85, green: 0.45, blue: 0.65, alpha: 1),
            eyeCol:   CGColor(red: 0.10, green: 0.80, blue: 0.85, alpha: 1),
            eyeDim:   CGColor(red: 0.20, green: 0.65, blue: 0.70, alpha: 1),
            noseCol:  CGColor(red: 0.35, green: 0.80, blue: 0.40, alpha: 1),
            pawCol:   CGColor(red: 0.92, green: 0.55, blue: 0.72, alpha: 1)
        )),
    ]

    static func variant(id: String) -> PetVariantDef? {
        all.first { $0.id == id }
    }
}
