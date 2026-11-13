import Foundation
import PearlCore

public enum MemoryPromotionDecision: Sendable, Equatable {
    case promoted(factId: String)
    case refused(reason: String)
    case queuedForReview(proposalId: String)
}

public actor LearningGate {
    public let store: MemoryStore
    public let proposalsURL: URL
    private var proposals: [ProposedFact] = []
    
    public init(store: MemoryStore) throws {
        self.store = store
        let url = store.baseDirectory.appendingPathComponent("pending_proposals.json")
        self.proposalsURL = url
        self.proposals = Self.loadProposalsFromDisk(at: url)
    }
    
    // MARK: - Explicit Remember with Undo Token
    
    /// Explicit "remember [fact]": writes immediately if trusted or user-confirmed.
    /// Returns the factId (undo token) and registers with UndoJournal.
    @discardableResult
    public func explicitRemember(
        fact: String,
        source: String = "user",
        trust: TrustLevel = .trusted,
        userConfirmed: Bool = false
    ) async throws -> (factId: String, undoAction: @Sendable () async throws -> Void) {
        // Untrusted-content gate: ANY input tagged as untrusted is strictly REJECTED
        // unless explicitly approved by user confirmation.
        if (trust == .untrusted || source != "user") && !userConfirmed {
            throw MemoryError.untrustedInputRejected(
                reason: "Untrusted source '\(source)' is forbidden from memory promotion without explicit user confirmation."
            )
        }
        
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MemoryError.invalidFormat("Fact content cannot be empty")
        }
        
        let memoryFact = MemoryFact(source: source, content: trimmed)
        try await store.addFact(memoryFact)
        
        let factId = memoryFact.id
        let capturedStore = self.store
        let undoAction: @Sendable () async throws -> Void = {
            _ = try await capturedStore.removeFact(id: factId)
        }
        
        await UndoJournal.shared.register(toolName: "remember", undoAction: undoAction)
        return (factId, undoAction)
    }
    
    /// Forget a fact by its ID (undo token).
    @discardableResult
    public func forget(factId: String) async throws -> Bool {
        return try await store.removeFact(id: factId)
    }
    
    // MARK: - Untrusted-Content Gate Evaluation
    
    /// Evaluates memory promotion candidate against untrusted content gate.
    /// Strictly blocks external/untrusted content (mail, web, calendar, files, MCP, etc.)
    /// unless explicitly confirmed by the user.
    public func evaluatePromotion(
        content: String,
        source: String,
        trust: TrustLevel = .untrusted,
        userConfirmed: Bool = false
    ) async throws -> MemoryPromotionDecision {
        let isUntrusted = (trust == .untrusted) || (source != "user")
        
        if isUntrusted && !userConfirmed {
            return .refused(
                reason: "Untrusted input from source '\(source)' rejected from memory promotion without user confirmation."
            )
        }
        
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .refused(reason: "Empty content cannot be promoted.")
        }
        
        let fact = MemoryFact(source: source, content: trimmed)
        try await store.addFact(fact)
        return .promoted(factId: fact.id)
    }
    
    // MARK: - Proposed Facts Queue (Implicit Learning)
    
    /// Implicit learning propositions (e.g. from background observations or sleep-time compute)
    /// are stored as pending proposals until the user explicitly approves.
    @discardableResult
    public func proposeFact(
        content: String,
        source: String,
        trust: TrustLevel = .trusted,
        confidence: Double = 1.0
    ) throws -> ProposedFact {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MemoryError.invalidFormat("Proposed fact content cannot be empty")
        }
        
        let proposal = ProposedFact(
            id: UUID().uuidString,
            content: trimmed,
            source: source,
            trust: trust,
            proposedAt: Date(),
            confidence: confidence,
            status: .pending
        )
        proposals.append(proposal)
        try saveProposals()
        return proposal
    }
    
    public func getPendingProposals() -> [ProposedFact] {
        return proposals.filter { $0.status == .pending }
    }
    
    public func getAllProposals() -> [ProposedFact] {
        return proposals
    }
    
    @discardableResult
    public func approveProposal(id: String) async throws -> MemoryFact {
        guard let index = proposals.firstIndex(where: { $0.id == id }) else {
            throw MemoryError.factNotFound(id: id)
        }
        guard proposals[index].status == .pending else {
            throw MemoryError.invalidFormat("Proposal \(id) is already \(proposals[index].status.rawValue)")
        }
        
        let p = proposals[index]
        let fact = MemoryFact(id: p.id, source: p.source, content: p.content)
        try await store.addFact(fact)
        
        proposals[index].status = .approved
        try saveProposals()
        return fact
    }
    
    public func rejectProposal(id: String) throws {
        guard let index = proposals.firstIndex(where: { $0.id == id }) else {
            throw MemoryError.factNotFound(id: id)
        }
        proposals[index].status = .rejected
        try saveProposals()
    }
    
    // MARK: - Proposal Storage Persistence
    
    private static func loadProposalsFromDisk(at url: URL) -> [ProposedFact] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode([ProposedFact].self, from: data)) ?? []
    }
    
    private func saveProposals() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(proposals)
        
        let dir = proposalsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tempURL = dir.appendingPathComponent(".pending_proposals.tmp.\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        
        if FileManager.default.fileExists(atPath: proposalsURL.path) {
            _ = try FileManager.default.replaceItemAt(proposalsURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: proposalsURL)
        }
    }
}
