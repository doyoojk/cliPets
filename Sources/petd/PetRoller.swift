import Foundation

/// Weighted random pet selection with an unseen-pet boost.
enum PetRoller {
    /// Roll a variant for a new session.
    ///
    /// - Parameter seenIds: Set of variant IDs already unlocked by this user.
    ///   Unseen variants get 2× weight so the collection fills in over time.
    static func roll(seenIds: Set<String>) -> PetVariantDef {
        let all = PetCatalog.all
        let weights = all.map { v -> Double in
            let base = v.rarity.weight / Double(count(ofRarity: v.rarity, in: all))
            return seenIds.contains(v.id) ? base : base * 2
        }
        let total = weights.reduce(0, +)
        var pick = Double.random(in: 0..<total)
        for (variant, weight) in zip(all, weights) {
            pick -= weight
            if pick <= 0 { return variant }
        }
        return all.last!
    }

    private static func count(ofRarity rarity: RarityTier, in variants: [PetVariantDef]) -> Int {
        max(1, variants.filter { $0.rarity == rarity }.count)
    }
}
