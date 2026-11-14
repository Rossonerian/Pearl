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
    /// Performs deduplication and entity fact correction.
    /// Returns the factId (undo token) and registers with UndoJournal.
    @discardableResult
    public func explicitRemember(
        fact: String,
        category: MemoryCategory = .semantic,
        source: String = "user",
        trust: TrustLevel = .trusted,
        userConfirmed: Bool = false,
        relatedEntityId: String? = nil
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
        
        let item = MemoryItem(
            category: category,
            content: trimmed,
            source: source,
            provenance: source,
            confidence: 1.0,
            sensitivity: .personal,
            userApproved: true,
            relatedEntityId: relatedEntityId
        )
        
        let (savedItem, _) = try await store.saveItem(item)
        let factId = savedItem.id
        let capturedStore = self.store
        
        let undoAction: @Sendable () async throws -> Void = {
            _ = try await capturedStore.removeItem(id: factId)
        }
        
        await UndoJournal.shared.register(toolName: "remember", undoAction: undoAction)
        return (factId, undoAction)
    }
    
    /// Forget a fact by its ID (undo token).
    @discardableResult
    public func forget(factId: String) async throws -> Bool {
        return try await store.removeItem(id: factId)
    }
    
    // MARK: - Untrusted-Content Gate Evaluation
    
    /// Evaluates memory promotion candidate against untrusted content gate.
    /// Strictly blocks external/untrusted content (mail, web, calendar, files, MCP, etc.)
    /// unless explicitly confirmed by the user.
    public func evaluatePromotion(
        content: String,
        category: MemoryCategory = .semantic,
        source: String,
        trust: TrustLevel = .untrusted,
        userConfirmed: Bool = false,
        relatedEntityId: String? = nil
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
        
        let item = MemoryItem(
            category: category,
            content: trimmed,
            source: source,
            provenance: source,
            confidence: 1.0,
            sensitivity: .personal,
            userApproved: true,
            relatedEntityId: relatedEntityId
        )
        let (savedItem, _) = try await store.saveItem(item)
        return .promoted(factId: savedItem.id)
    }
    
    // MARK: - Proposed Facts Queue (Implicit Learning)
    
    /// Implicit learning propositions (e.g. from background observations or sleep-time compute)
    /// are stored as pending proposals until the user explicitly approves.
    @discardableResult
    public func proposeFact(
        content: String,
        category: MemoryCategory = .semantic,
        source: String,
        trust: TrustLevel = .trusted,
        confidence: Double = 1.0,
        relatedEntityId: String? = nil
    ) throws -> ProposedFact {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MemoryError.invalidFormat("Proposed fact content cannot be empty")
        }
        
        let proposal = ProposedFact(
            id: UUID().uuidString,
            category: category,
            content: trimmed,
            source: source,
            trust: trust,
            proposedAt: Date(),
            confidence: confidence,
            status: .pending,
            relatedEntityId: relatedEntityId
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
    public func approveProposal(id: String) async throws -> MemoryItem {
        guard let index = proposals.firstIndex(where: { $0.id == id }) else {
            throw MemoryError.factNotFound(id: id)
        }
        guard proposals[index].status == .pending else {
            throw MemoryError.invalidFormat("Proposal \(id) is already \(proposals[index].status.rawValue)")
        }
        
        let p = proposals[index]
        let item = MemoryItem(
            id: p.id,
            category: p.category,
            content: p.content,
            source: p.source,
            provenance: p.source,
            confidence: p.confidence,
            sensitivity: .personal,
            userApproved: true,
            relatedEntityId: p.relatedEntityId
        )
        let (savedItem, _) = try await store.saveItem(item)
        
        proposals[index].status = .approved
        try saveProposals()
        return savedItem
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
