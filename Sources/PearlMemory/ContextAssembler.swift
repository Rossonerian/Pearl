import Foundation
import PearlCore

public struct MemoryContext: Sendable, Codable {
    public let profile: String
    public let profileTokens: Int
    public let persona: String
    public let retrievedSnippets: [MemorySnippet]
    public let promptSection: String
    public let totalEstimatedTokens: Int
    public let isWithinBudget: Bool
    
    public init(
        profile: String,
        profileTokens: Int,
        persona: String,
        retrievedSnippets: [MemorySnippet],
        promptSection: String,
        totalEstimatedTokens: Int,
        isWithinBudget: Bool
    ) {
        self.profile = profile
        self.profileTokens = profileTokens
        self.persona = persona
        self.retrievedSnippets = retrievedSnippets
        self.promptSection = promptSection
        self.totalEstimatedTokens = totalEstimatedTokens
        self.isWithinBudget = isWithinBudget
    }
}

public enum ContextAssembler {
    /// Assembles context for prompt injection:
    /// - `profile.md`: guaranteed <= 600 tokens and <= 1.5 KB
    /// - `persona.md`: system persona
    /// - `retrievedSnippets`: dynamically retrieved snippets, capped at <= 5
    /// - Note: `journal` scratch notes are strictly filtered and NEVER auto-injected.
    public static func assemble(
        query: String,
        store: MemoryStore,
        topK: Int = 5
    ) async throws -> MemoryContext {
        let profile = await store.getProfile()
        let profileTokens = estimateTokenCount(profile)
        
        guard profileTokens <= ContextBudget.maxProfileTokens else {
            throw MemoryError.profileExceedsBudget(bytes: profile.utf8.count, tokens: profileTokens)
        }
        
        let persona = await store.getPersona()
        
        // Search FTS5: topK capped at maxRetrievedSnippets (<= 5)
        let rawSnippets = await store.search(query: query, topK: min(topK, ContextBudget.maxRetrievedSnippets))
        
        // Requirement: journal entries are scratch notes, NEVER auto-injected
        let filteredSnippets = rawSnippets.filter { $0.sourceType != "journal" }
        let cappedSnippets = Array(filteredSnippets.prefix(ContextBudget.maxRetrievedSnippets))
        
        var sections: [String] = []
        
        if !persona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("### System Persona\n\(persona)")
        }
        
        if !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("### Stated User Profile\n\(profile)")
        }
        
        if !cappedSnippets.isEmpty {
            var snippetLines: [String] = ["### Relevant Memory Context"]
            for snippet in cappedSnippets {
                snippetLines.append("- (\(snippet.date)) \(snippet.content)")
            }
            sections.append(snippetLines.joined(separator: "\n"))
        }
        
        let fullText = sections.joined(separator: "\n\n")
        let totalTokens = estimateTokenCount(fullText)
        let withinBudget = profileTokens <= ContextBudget.maxProfileTokens &&
                           cappedSnippets.count <= ContextBudget.maxRetrievedSnippets
        
        return MemoryContext(
            profile: profile,
            profileTokens: profileTokens,
            persona: persona,
            retrievedSnippets: cappedSnippets,
            promptSection: fullText,
            totalEstimatedTokens: totalTokens,
            isWithinBudget: withinBudget
        )
    }
}
