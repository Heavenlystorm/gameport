import Foundation

/// Which games carry anti-cheat that Wine on a Mac cannot satisfy, known before anything is downloaded.
/// Data: highball-db's map (Data/anticheat/), derived from Are We Anti-Cheat Yet? under MIT.
/// GamePort only reports this; it never works around anti-cheat.
public struct AntiCheatEntry: Codable, Sendable, Equatable {
    public enum MacVerdict: String, Codable, Sendable {
        case blocked    // kernel-level anti-cheat: cannot run under Wine at all
        case warning    // anti-cheat present: depends on whether the developer allows Wine
    }

    public var id: String
    public var title: String
    public var antiCheats: [String]
    /// Are We Anti-Cheat Yet?'s Linux/Proton status: Supported, Running, Planned, Broken or Denied.
    public var linuxStatus: String
    public var steamAppID: Int?
    public var macVerdict: MacVerdict

    public enum Risk: Sendable, Equatable {
        case blocked        // never works
        case onlineDenied   // anti-cheat refuses Wine/Proton: online play almost certainly fails
        case caution        // allowed on Linux/Proton, not verified on a Mac
    }

    public var risk: Risk {
        if macVerdict == .blocked { return .blocked }
        switch linuxStatus {
        case "Supported", "Running": return .caution
        default: return .onlineDenied   // Denied, Broken, Planned
        }
    }

    /// One-liner for the game page and the CLI.
    public var summary: String {
        let names = antiCheats.isEmpty ? "anti-cheat" : antiCheats.joined(separator: ", ")
        switch risk {
        case .blocked: return "Will not run: \(names) runs in the kernel and is not supported under Wine"
        case .onlineDenied:
            let why = linuxStatus == "Denied" ? "blocks Linux/Wine" : "does not work on Linux/Wine"
            return "Online play will most likely fail: \(names) \(why)"
        case .caution:
            let state = linuxStatus == "Supported" ? "supported" : "working"
            return "Anti-cheat: \(names). \(state.capitalized) on Linux, not verified on Mac"
        }
    }
}

public struct AntiCheatDB: Sendable {
    public let entries: [AntiCheatEntry]
    let byAppID: [Int: AntiCheatEntry]
    let byID: [String: AntiCheatEntry]

    public init(entries: [AntiCheatEntry]) {
        self.entries = entries
        byAppID = Dictionary(entries.compactMap { e in e.steamAppID.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
        byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public static let bundled: AntiCheatDB = {
        struct File: Decodable { var games: [AntiCheatEntry] }
        let games = (try? JSONDecoder().decode(File.self, from: Data(BundledData.antiCheat.utf8)).games) ?? []
        return AntiCheatDB(entries: games)
    }()

    public func entry(steamAppID: Int) -> AntiCheatEntry? { byAppID[steamAppID] }

    /// By Steam app id first, then by the recipe id (both use the same lowercase-dash slugs).
    public func entry(for recipe: Recipe) -> AntiCheatEntry? {
        recipe.steamAppID.flatMap { byAppID[$0] } ?? byID[recipe.id]
    }

    /// A Steam app id, or words that all appear in the title (case- and accent-insensitive).
    public func search(_ query: String, limit: Int = 10) -> [AntiCheatEntry] {
        if let appID = Int(query.trimmingCharacters(in: .whitespaces)) { return entry(steamAppID: appID).map { [$0] } ?? [] }
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.filter { e in
            let title = e.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy { title.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
        }.prefix(limit).map { $0 }
    }
}
