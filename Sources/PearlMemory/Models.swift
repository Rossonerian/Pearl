import Foundation
import PearlCore

public enum MemoryError: LocalizedError, Sendable, Equatable {
    case personaReadOnly(String)
    case profileExceedsBudget(bytes: Int, tokens: Int)
    case untrustedInputRejected(reason: String)
    case factNotFound(id: String)
    case databaseError(String)
    case ioError(String)
    case invalidFormat(String)
    case migrationError(String)
    
    public var errorDescription: String? {
        switch self {
        case .personaReadOnly(let reason):
            return "Persona is read-only: \(reason)"
        case .profileExceedsBudget(let bytes, let tokens):
            return "Profile exceeds budget: \(bytes) bytes, \(tokens) estimated tokens (budget: max 1536 bytes, 600 tokens)"
        case .untrustedInputRejected(let reason):
            return "Untrusted input rejected: \(reason)"
        case .factNotFound(let id):
            return "Fact with id '\(id)' not found"
        case .databaseError(let message):
            return "Database error: \(message)"
        case .ioError(let message):
            return "I/O error: \(message)"
        case .invalidFormat(let message):
            return "Invalid format: \(message)"
        case .migrationError(let message):
            return "Migration error: \(message)"
        }
    }
}

// MARK: - Memory Category & Sensitivity

/// The 6 required memory classes for Pearl V3.
public enum MemoryCategory: String, Codable, Sendable, CaseIterable {
    /// Stable preferences, name, hardware, environment.
    case profile
    /// Factual knowledge, relationships, domain knowledge.
    case semantic
    /// Repo name, active branches, technical decisions, milestones.
    case project
    /// Summaries of meaningful past turns, conversations, reflections.
    case episodic
    /// Bounded current conversational scratchpad, transient working notes.
    case working
    /// Deadlines, follow-ups, scheduled commitments.
    case task
}

/// Sensitivity classification for stored memory items.
public enum MemorySensitivity: String, Codable, Sendable, CaseIterable {
    case `public` = "public"
    case personal = "personal"
    case sensitive = "sensitive"
}

// MARK: - MemoryItem (Canonical V3 Structured Model)

/// Canonical structured memory record matching the SQLite `memories` table schema.
public struct MemoryItem: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var category: MemoryCategory
    public var content: String
    public var source: String
    public var provenance: String
    public var confidence: Double
    public var sensitivity: MemorySensitivity
    public var userApproved: Bool
    public var createdAt: String
    public var updatedAt: String
    public var validUntil: String?
    public var relatedEntityId: String?
    
    public init(
        id: String = UUID().uuidString,
        category: MemoryCategory = .semantic,
        content: String,
        source: String = "user",
        provenance: String = "user",
        confidence: Double = 1.0,
        sensitivity: MemorySensitivity = .personal,
        userApproved: Bool = true,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        validUntil: String? = nil,
        relatedEntityId: String? = nil
    ) {
        let now = Self.currentISO8601String()
        self.id = id
        self.category = category
        self.content = content
        self.source = source
        self.provenance = provenance
        self.confidence = max(0.0, min(1.0, confidence))
        self.sensitivity = sensitivity
        self.userApproved = userApproved
        self.createdAt = createdAt ?? now
        self.updatedAt = updatedAt ?? now
        self.validUntil = validUntil
        self.relatedEntityId = relatedEntityId
    }
    
    public static func currentISO8601String() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
    
    public var dateString: String {
        if createdAt.count >= 10 {
            return String(createdAt.prefix(10))
        }
        return MemoryFact.currentDateString()
    }
    
    /// Converts to standard backwards-compatible MemoryFact.
    public var asMemoryFact: MemoryFact {
        return MemoryFact(id: id, source: source, date: dateString, content: content)
    }
    
    /// Serializes memory item to inspectable Markdown bullet:
    /// `- [id: <id>] (<source>, <date>): <content>` (for semantic facts)
    /// `- [id: <id>] (<source>, <date>) [category: <category>]: <content>` (for other classes)
    public func toMarkdownBullet() -> String {
        if category == .semantic {
            return "- [id: \(id)] (\(source), \(dateString)): \(content)"
        } else {
            return "- [id: \(id)] (\(source), \(dateString)) [category: \(category.rawValue)]: \(content)"
        }
    }
    
    /// Parses a markdown bullet line into a MemoryItem.
    /// Handles both legacy `- [id: ...] (source, date): content`
    /// and V3 `- [id: ...] (source, date) [category: cat]: content`.
    public static func parseBullet(_ rawLine: String) -> MemoryItem? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else {
            return nil
        }
        
        let trimmed = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[id: ") else {
            return nil
        }
        
        guard let idEnd = trimmed.range(of: "]") else {
            return nil
        }
        
        let idStart = trimmed.index(trimmed.startIndex, offsetBy: 5)
        let id = String(trimmed[idStart..<idEnd.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        
        let afterId = String(trimmed[idEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard afterId.hasPrefix("(") else { return nil }
        
        guard let metaEnd = afterId.range(of: ")") else { return nil }
        let metaStart = afterId.index(afterId.startIndex, offsetBy: 1)
        let metaStr = String(afterId[metaStart..<metaEnd.lowerBound])
        
        let metaParts = metaStr.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard metaParts.count == 2 else { return nil }
        let source = metaParts[0]
        let date = metaParts[1]
        
        var remainder = String(afterId[metaEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
        var category: MemoryCategory = .semantic
        
        // Check for optional [category: ...]
        if remainder.hasPrefix("[category: ") {
            if let catEnd = remainder.range(of: "]") {
                let catStart = remainder.index(remainder.startIndex, offsetBy: 11)
                let catStr = String(remainder[catStart..<catEnd.lowerBound]).trimmingCharacters(in: .whitespaces)
                if let parsedCat = MemoryCategory(rawValue: catStr) {
                    category = parsedCat
                }
                remainder = String(remainder[catEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        
        guard remainder.hasPrefix(":") else { return nil }
        let contentStart = remainder.index(remainder.startIndex, offsetBy: 1)
        let content = String(remainder[contentStart...]).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        
        return MemoryItem(
            id: id,
            category: category,
            content: content,
            source: source,
            provenance: source,
            confidence: 1.0,
            sensitivity: .personal,
            userApproved: true,
            createdAt: date,
            updatedAt: date
        )
    }
}

// MARK: - Legacy MemoryFact (Backwards Compatibility)

public struct MemoryFact: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let source: String
    public let date: String // YYYY-MM-DD
    public let content: String
    
    public init(id: String = UUID().uuidString, source: String = "user", date: String? = nil, content: String) {
        self.id = id
        self.source = source
        self.date = date ?? Self.currentDateString()
        self.content = content
    }
    
    public static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }
    
    public var asMemoryItem: MemoryItem {
        return MemoryItem(
            id: id,
            category: .semantic,
            content: content,
            source: source,
            provenance: source,
            confidence: 1.0,
            sensitivity: .personal,
            userApproved: true,
            createdAt: date,
            updatedAt: date
        )
    }
    
    /// Serializes fact to standard Markdown bullet format:
    /// `- [id: <id>] (<source>, <date>): <content>`
    public func toMarkdownBullet() -> String {
        return "- [id: \(id)] (\(source), \(date)): \(content)"
    }
    
    /// Parses a markdown bullet line into a MemoryFact.
    /// Supports legacy format and category-tagged format.
    public static func parseBullet(_ rawLine: String) -> MemoryFact? {
        if let item = MemoryItem.parseBullet(rawLine) {
            return item.asMemoryFact
        }
        
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else {
            return nil
        }
        
        let trimmed = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[id: ") else {
            return nil
        }
        
        guard let idEnd = trimmed.range(of: "]") else {
            return nil
        }
        
        let idStart = trimmed.index(trimmed.startIndex, offsetBy: 5)
        let id = String(trimmed[idStart..<idEnd.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        
        let afterId = String(trimmed[idEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard afterId.hasPrefix("(") else { return nil }
        
        guard let metaEnd = afterId.range(of: ")") else { return nil }
        let metaStart = afterId.index(afterId.startIndex, offsetBy: 1)
        let metaStr = String(afterId[metaStart..<metaEnd.lowerBound])
        
        let metaParts = metaStr.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard metaParts.count == 2 else { return nil }
        let source = metaParts[0]
        let date = metaParts[1]
        
        let afterMeta = String(afterId[metaEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard afterMeta.hasPrefix(":") else { return nil }
        
        let contentStart = afterMeta.index(afterMeta.startIndex, offsetBy: 1)
        let content = String(afterMeta[contentStart...]).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        
        return MemoryFact(id: id, source: source, date: date, content: content)
    }
}

// MARK: - MemorySnippet

public struct MemorySnippet: Codable, Sendable, Identifiable, Equatable, MemorySnippetProtocol {
    public let id: String
    public let category: MemoryCategory
    public let sourceType: String // "fact", "profile", "journal", or category rawValue
    public let filePath: String
    public let date: String
    public let content: String
    public let bm25Score: Double
    
    public init(
        id: String,
        category: MemoryCategory = .semantic,
        sourceType: String,
        filePath: String,
        date: String,
        content: String,
        bm25Score: Double
    ) {
        self.id = id
        self.category = category
        self.sourceType = sourceType
        self.filePath = filePath
        self.date = date
        self.content = content
        self.bm25Score = bm25Score
    }
}

// MARK: - ProposedFact

public struct ProposedFact: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable {
        case pending
        case approved
        case rejected
    }
    
    public let id: String
    public let category: MemoryCategory
    public let content: String
    public let source: String
    public let trust: TrustLevel
    public let proposedAt: Date
    public let confidence: Double
    public var status: Status
    public let relatedEntityId: String?
    
    public init(
        id: String = UUID().uuidString,
        category: MemoryCategory = .semantic,
        content: String,
        source: String,
        trust: TrustLevel = .trusted,
        proposedAt: Date = Date(),
        confidence: Double = 1.0,
        status: Status = .pending,
        relatedEntityId: String? = nil
    ) {
        self.id = id
        self.category = category
        self.content = content
        self.source = source
        self.trust = trust
        self.proposedAt = proposedAt
        self.confidence = confidence
        self.status = status
        self.relatedEntityId = relatedEntityId
    }
}

// MARK: - MemoryExport

public struct MemoryExport: Codable, Sendable {
    public let schemaVersion: Int
    public let exportedAt: Date
    public let profile: String
    public let persona: String
    public let facts: [MemoryFact]
    public let items: [MemoryItem]
    public let pendingProposals: [ProposedFact]
    
    public init(
        schemaVersion: Int,
        exportedAt: Date = Date(),
        profile: String,
        persona: String,
        facts: [MemoryFact],
        items: [MemoryItem] = [],
        pendingProposals: [ProposedFact]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.profile = profile
        self.persona = persona
        self.facts = facts
        self.items = items.isEmpty ? facts.map { $0.asMemoryItem } : items
        self.pendingProposals = pendingProposals
    }
}

// MARK: - MemoryStats

public struct MemoryStats: Codable, Sendable {
    public let schemaVersion: Int
    public let factCount: Int
    public let profileByteCount: Int
    public let profileEstimatedTokens: Int
    public let pendingProposalsCount: Int
    public let categoryCounts: [String: Int]
    
    public init(
        schemaVersion: Int,
        factCount: Int,
        profileByteCount: Int,
        profileEstimatedTokens: Int,
        pendingProposalsCount: Int,
        categoryCounts: [String: Int] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.factCount = factCount
        self.profileByteCount = profileByteCount
        self.profileEstimatedTokens = profileEstimatedTokens
        self.pendingProposalsCount = pendingProposalsCount
        self.categoryCounts = categoryCounts
    }
}

// MARK: - Token Estimation

/// Conservative token estimation for English text and structured markdown.
/// Uses character and word boundary heuristics.
public func estimateTokenCount(_ text: String) -> Int {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return 0 }
    
    let words = trimmed.split { $0.isWhitespace || $0.isPunctuation }.count
    let wordTokens = Double(words) * 1.3
    let charTokens = Double(trimmed.utf8.count) / 3.8
    
    return max(1, Int(ceil(max(wordTokens, charTokens))))
}
