import Foundation
import PearlCore

/// The result of an associative dream synthesis run.
public struct DreamSynthesis: Codable, Sendable, Equatable {
    public let title: String
    public let sharedThemes: [String]
    public let bridgeNarrative: String
    public let sourceNotes: [String]
    public let savedNotePath: String
    
    public init(
        title: String,
        sharedThemes: [String],
        bridgeNarrative: String,
        sourceNotes: [String],
        savedNotePath: String
    ) {
        self.title = title
        self.sharedThemes = sharedThemes
        self.bridgeNarrative = bridgeNarrative
        self.sourceNotes = sourceNotes
        self.savedNotePath = savedNotePath
    }
}

/// Errors occurring during dream consolidation.
public enum DreamError: Error, LocalizedError, Equatable {
    case insufficientMemories(Int)
    
    public var errorDescription: String? {
        switch self {
        case .insufficientMemories(let count):
            return "Insufficient memories for dream synthesis (found \(count), required at least 2)."
        }
    }
}

private struct RawMemoryUnit {
    let source: String
    let content: String
    let timestamp: Date
}

/// Consolidates past memories and vault notes into thematic synthesis dreams.
public final class DreamEngine: @unchecked Sendable {
    public static let shared = DreamEngine()
    
    public let vaultManager: VaultManager
    public let memoryStore: MemoryStore?
    
    public init(vaultManager: VaultManager = .shared, memoryStore: MemoryStore? = nil) {
        self.vaultManager = vaultManager
        self.memoryStore = memoryStore
    }
    
    private static let stopWords: Set<String> = [
        "about", "above", "after", "again", "against", "agent", "all", "also", "always",
        "and", "any", "are", "aren't", "because", "been", "before", "being", "below",
        "between", "both", "but", "can", "cannot", "could", "couldn't", "date", "did",
        "didn't", "does", "doesn't", "doing", "don't", "down", "during", "each", "even",
        "ever", "every", "few", "first", "for", "from", "further", "had", "hadn't",
        "has", "hasn't", "have", "haven't", "having", "here", "how", "into", "itself",
        "just", "like", "made", "make", "many", "memory", "more", "most", "must",
        "note", "only", "other", "our", "ours", "out", "over", "same", "should",
        "some", "such", "tags", "than", "that", "their", "theirs", "them", "then",
        "there", "these", "they", "this", "those", "through", "title", "under", "until",
        "very", "were", "what", "when", "where", "which", "while", "with", "would",
        "your", "yours"
    ]
    
    private func extractKeywords(from text: String) -> [String] {
        let lower = text.lowercased()
        let tokens = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return tokens.compactMap { token in
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 4 else { return nil }
            guard trimmed.allSatisfy({ $0.isLetter }) else { return nil }
            guard !Self.stopWords.contains(trimmed) else { return nil }
            return trimmed
        }
    }
    
    /// Synthesizes an associative dream note from vault notes, memoryStore items, and extra fragments.
    public func synthesizeDream(extraFragments: [String] = [], date: Date = Date()) async throws -> DreamSynthesis {
        var items: [RawMemoryUnit] = []
        
        // 1. Gather notes from VaultManager (skipping prior Dreams to prevent recursion)
        let notePaths = vaultManager.listNotes()
        for path in notePaths {
            if path.hasPrefix("Dreams/") { continue }
            if let noteContent = vaultManager.readNote(name: path) {
                let sourceName = (path as NSString).deletingPathExtension
                let fileURL = vaultManager.vaultURL.appendingPathComponent(path)
                let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? date
                items.append(RawMemoryUnit(source: sourceName, content: noteContent, timestamp: modDate))
            }
        }
        
        // 2. Gather from MemoryStore if configured
        if let memoryStore = self.memoryStore {
            let memoryItems = await memoryStore.getAllItems()
            for mem in memoryItems {
                let memDate = ISO8601DateFormatter().date(from: mem.createdAt) ?? date
                let src = "Memory:\(mem.category.rawValue)"
                items.append(RawMemoryUnit(source: src, content: mem.content, timestamp: memDate))
            }
        }
        
        // 3. Extra fragments
        for (idx, fragment) in extraFragments.enumerated() {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            items.append(RawMemoryUnit(
                source: "Fragment-\(idx + 1)",
                content: trimmed,
                timestamp: date
            ))
        }
        
        // Requires at least 2 distinct memory items
        guard items.count >= 2 else {
            throw DreamError.insufficientMemories(items.count)
        }
        
        // Sort items temporally
        let sorted = items.sorted(by: { $0.timestamp < $1.timestamp })
        
        // Split into earliest vs most-recent memory clusters
        let mid = max(1, sorted.count / 2)
        let earliestCluster = Array(sorted[0..<mid])
        let recentCluster = Array(sorted[mid..<sorted.count])
        
        let earliestKeywords = earliestCluster.flatMap { extractKeywords(from: $0.content) }
        let recentKeywords = recentCluster.flatMap { extractKeywords(from: $0.content) }
        
        let earliestSet = Set(earliestKeywords)
        let recentSet = Set(recentKeywords)
        
        var freq: [String: Int] = [:]
        for kw in (earliestKeywords + recentKeywords) {
            freq[kw, default: 0] += 1
        }
        
        let common = earliestSet.intersection(recentSet)
        var sharedThemes: [String] = []
        
        if !common.isEmpty {
            sharedThemes = common.sorted { (freq[$0] ?? 0) > (freq[$1] ?? 0) }
        } else {
            // Bridge themes by taking prominent keywords across both clusters
            var bridgeKws: [String] = []
            let topEarliest = earliestKeywords.sorted { (freq[$0] ?? 0) > (freq[$1] ?? 0) }
            let topRecent = recentKeywords.sorted { (freq[$0] ?? 0) > (freq[$1] ?? 0) }
            
            for kw in topEarliest where !bridgeKws.contains(kw) {
                bridgeKws.append(kw)
                if bridgeKws.count >= 2 { break }
            }
            for kw in topRecent where !bridgeKws.contains(kw) {
                bridgeKws.append(kw)
                if bridgeKws.count >= 4 { break }
            }
            sharedThemes = bridgeKws
        }
        
        if sharedThemes.isEmpty {
            sharedThemes = ["continuity", "synthesis"]
        }
        
        // Distinct source note names
        var uniqueSources: [String] = []
        for it in sorted {
            if !uniqueSources.contains(it.source) {
                uniqueSources.append(it.source)
            }
        }
        
        // Build concise narrative with wikilinks
        let topThemeStr = sharedThemes.prefix(3).joined(separator: ", ")
        let wikilinkChain = uniqueSources.map { "[[\($0)]]" }.joined(separator: " and ")
        
        let bridgeNarrative = "Bridging foundational memories from \(wikilinkChain): shared patterns in \(topThemeStr) illuminate ongoing progress and recurring focus areas."
        
        let dateSlugFormatter = DateFormatter()
        dateSlugFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateSlugFormatter.dateFormat = "yyyy-MM-dd"
        let dateSlug = dateSlugFormatter.string(from: date)
        
        let dreamTitle = "Dream Synthesis - \(dateSlug)"
        let dreamBody = """
        # \(dreamTitle)

        ## Narrative Synthesis
        \(bridgeNarrative)

        ### Key Themes
        \(sharedThemes.map { "- \($0)" }.joined(separator: "\n"))
        """
        
        let savedPath = "Dreams/\(dateSlug).md"
        try vaultManager.writeNote(
            name: savedPath,
            content: dreamBody,
            tags: ["dream", "synthesis"],
            wikilinks: uniqueSources,
            date: date
        )
        
        return DreamSynthesis(
            title: dreamTitle,
            sharedThemes: sharedThemes,
            bridgeNarrative: bridgeNarrative,
            sourceNotes: uniqueSources,
            savedNotePath: savedPath
        )
    }
}
