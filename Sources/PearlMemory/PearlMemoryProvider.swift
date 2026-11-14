import Foundation
import PearlCore

/// Canonical implementation of `MemoryContextProvider` bridging `PearlMemory`
/// storage, learning gates, and FTS5 retrieval into `AssistantPipeline`.
public final class PearlMemoryProvider: MemoryContextProvider, Sendable {
    public static let shared = PearlMemoryProvider()
    
    public init() {}
    
    public func assembleContext(query: String) async throws -> String {
        let store = try MemoryStore()
        let context = try await ContextAssembler.assemble(query: query, store: store)
        return context.promptSection
    }
    
    public func explicitRemember(fact: String, trust: TrustLevel) async throws -> String {
        let store = try MemoryStore()
        let gate = try LearningGate(store: store)
        let (factId, _) = try await gate.explicitRemember(fact: fact, source: "user", trust: trust)
        return factId
    }
    
    public func forget(factId: String) async throws -> Bool {
        let store = try MemoryStore()
        let gate = try LearningGate(store: store)
        return try await gate.forget(factId: factId)
    }
    
    public func proposePreferenceIfApplicable(utterance: String, trust: TrustLevel) async {
        guard let store = try? MemoryStore(),
              let gate = try? LearningGate(store: store) else {
            return
        }
        _ = try? await gate.detectAndProposePreference(from: utterance, source: "user", trust: trust)
    }
    
    public func triggerDreamSynthesis() async throws -> String {
        let store = try? MemoryStore()
        let engine = DreamEngine(vaultManager: .shared, memoryStore: store)
        let dream = try await engine.synthesizeDream()
        let themes = dream.sharedThemes.prefix(4).joined(separator: ", ")
        let sources = dream.sourceNotes.map { "[[\($0)]]" }.joined(separator: ", ")
        return """
        Dream Synthesis complete: **\(dream.title)**
        Saved note: `\(dream.savedNotePath)`
        Themes: \(themes)
        Connections: \(sources.isEmpty ? "none" : sources)
        \(dream.bridgeNarrative)
        """
    }
}
