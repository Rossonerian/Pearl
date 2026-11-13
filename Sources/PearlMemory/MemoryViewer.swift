import Foundation
import PearlCore

public actor MemoryViewer {
    public let store: MemoryStore
    public let gate: LearningGate
    
    public init(store: MemoryStore, gate: LearningGate) {
        self.store = store
        self.gate = gate
    }
    
    public func exportAll() async throws -> MemoryExport {
        let profile = await store.getProfile()
        let persona = await store.getPersona()
        let facts = await store.getAllFacts()
        let pending = await gate.getPendingProposals()
        let version = await store.ftsIndex.getSchemaVersion()
        
        return MemoryExport(
            schemaVersion: version,
            exportedAt: Date(),
            profile: profile,
            persona: persona,
            facts: facts,
            pendingProposals: pending
        )
    }
    
    public func exportJSON(prettyPrinted: Bool = true) async throws -> String {
        let exportObj = try await exportAll()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        let data = try encoder.encode(exportObj)
        return String(decoding: data, as: UTF8.self)
    }
    
    @discardableResult
    public func forget(factId: String) async throws -> Bool {
        return try await store.removeFact(id: factId)
    }
    
    public func clearAllFacts() async throws {
        try await store.clearAllFacts()
    }
    
    public func getStats() async throws -> MemoryStats {
        let facts = await store.getAllFacts()
        let profile = await store.getProfile()
        let pending = await gate.getPendingProposals()
        let version = await store.ftsIndex.getSchemaVersion()
        
        let profileBytes = profile.utf8.count
        let profileTokens = estimateTokenCount(profile)
        
        return MemoryStats(
            schemaVersion: version,
            factCount: facts.count,
            profileByteCount: profileBytes,
            profileEstimatedTokens: profileTokens,
            pendingProposalsCount: pending.count
        )
    }
}
