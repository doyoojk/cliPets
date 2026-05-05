import Foundation

/// Tracks unlocked variants and the variant assigned to each session.
/// Persisted to ~/.clipets/collection.json.
final class PetCollection {
    private let path: URL
    private var data: CollectionData

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir  = home.appendingPathComponent(".clipets")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("collection.json")
        data = (try? JSONDecoder().decode(CollectionData.self, from: Data(contentsOf: path)))
            ?? CollectionData()
    }

    // MARK: - Session assignment

    /// Returns the variant assigned to a session, rolling a new one if needed.
    /// If the variant is new, returns it flagged as a fresh unlock.
    func variantForSession(_ sessionId: String) -> (variant: PetVariantDef, isNew: Bool) {
        if let existing = data.sessionVariants[sessionId],
           let def = PetCatalog.variant(id: existing) {
            return (def, false)
        }
        let rolled = PetRoller.roll(seenIds: data.unlockedIds)
        data.sessionVariants[sessionId] = rolled.id
        let isNew = !data.unlockedIds.contains(rolled.id)
        if isNew { data.unlockedIds.insert(rolled.id) }
        save()
        return (rolled, isNew)
    }

    func removeSession(_ sessionId: String) {
        data.sessionVariants.removeValue(forKey: sessionId)
        save()
    }

    var unlockedIds: Set<String> { data.unlockedIds }

    // MARK: - Persistence

    private func save() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: path, options: .atomic)
    }

    // MARK: - Data model

    private struct CollectionData: Codable {
        var unlockedIds: Set<String> = []
        var sessionVariants: [String: String] = [:]
    }
}
