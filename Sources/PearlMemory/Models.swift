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
        }
    }
}

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
    
    /// Serializes fact to standard Markdown bullet format:
    /// `- [id: <id>] (<source>, <date>): <content>`
    public func toMarkdownBullet() -> String {
        return "- [id: \(id)] (\(source), \(date)): \(content)"
    }
    
    /// Parses a markdown bullet line into a MemoryFact.
    /// Returns nil for headers, comments, or malformed lines.
    public static func parseBullet(_ rawLine: String) -> MemoryFact? {
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

public struct MemorySnippet: Codable, Sendable, Identifiable, Equatable, MemorySnippetProtocol {
    public let id: String
    public let sourceType: String // "fact", "profile", "journal"
    public let filePath: String
    public let date: String
    public let content: String
    public let bm25Score: Double
    
    public init(
        id: String,
        sourceType: String,
        filePath: String,
        date: String,
        content: String,
        bm25Score: Double
    ) {
        self.id = id
        self.sourceType = sourceType
        self.filePath = filePath
        self.date = date
        self.content = content
        self.bm25Score = bm25Score
    }
}

public struct ProposedFact: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable {
        case pending
        case approved
        case rejected
    }
    
    public let id: String
    public let content: String
    public let source: String
    public let trust: TrustLevel
    public let proposedAt: Date
    public let confidence: Double
    public var status: Status
    
    public init(
        id: String = UUID().uuidString,
        content: String,
        source: String,
        trust: TrustLevel = .trusted,
        proposedAt: Date = Date(),
        confidence: Double = 1.0,
        status: Status = .pending
    ) {
        self.id = id
        self.content = content
        self.source = source
        self.trust = trust
        self.proposedAt = proposedAt
        self.confidence = confidence
        self.status = status
    }
}

public struct MemoryExport: Codable, Sendable {
    public let schemaVersion: Int
    public let exportedAt: Date
    public let profile: String
    public let persona: String
    public let facts: [MemoryFact]
    public let pendingProposals: [ProposedFact]
    
    public init(
        schemaVersion: Int,
        exportedAt: Date = Date(),
        profile: String,
        persona: String,
        facts: [MemoryFact],
        pendingProposals: [ProposedFact]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.profile = profile
        self.persona = persona
        self.facts = facts
        self.pendingProposals = pendingProposals
    }
}

public struct MemoryStats: Codable, Sendable {
    public let schemaVersion: Int
    public let factCount: Int
    public let profileByteCount: Int
    public let profileEstimatedTokens: Int
    public let pendingProposalsCount: Int
    
    public init(
        schemaVersion: Int,
        factCount: Int,
        profileByteCount: Int,
        profileEstimatedTokens: Int,
        pendingProposalsCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.factCount = factCount
        self.profileByteCount = profileByteCount
        self.profileEstimatedTokens = profileEstimatedTokens
        self.pendingProposalsCount = pendingProposalsCount
    }
}

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
