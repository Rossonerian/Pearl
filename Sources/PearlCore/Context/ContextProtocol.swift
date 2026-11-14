import Foundation

/// Defines the hard context budget for Pearl LLM prompts.
public struct ContextBudget: Sendable, Codable, Equatable {
    /// Strict upper limit on always-in-context profile tokens (~1.5 KB markdown).
    public static let maxProfileTokens: Int = 600
    
    /// Strict upper limit on profile file size in bytes.
    public static let maxProfileSizeBytes: Int = 1536
    
    /// Strict upper limit on dynamically retrieved memory snippets.
    public static let maxRetrievedSnippets: Int = 5
    
    public let profileTokens: Int
    public let retrievedSnippetCount: Int
    public let totalTokens: Int
    
    public init(profileTokens: Int, retrievedSnippetCount: Int, totalTokens: Int) {
        self.profileTokens = profileTokens
        self.retrievedSnippetCount = retrievedSnippetCount
        self.totalTokens = totalTokens
    }
    
    public var isWithinBudget: Bool {
        return profileTokens <= ContextBudget.maxProfileTokens &&
               retrievedSnippetCount <= ContextBudget.maxRetrievedSnippets
    }
}

/// Abstract representation of a retrieved memory snippet for prompt injection.
public protocol MemorySnippetProtocol: Sendable {
    var id: String { get }
    var sourceType: String { get }
    var filePath: String { get }
    var date: String { get }
    var content: String { get }
    var bm25Score: Double { get }
}

/// Abstract provider interface connecting PearlMemory to the core assistant pipeline.
public protocol MemoryContextProvider: Sendable {
    func assembleContext(query: String) async throws -> String
    func explicitRemember(fact: String, trust: TrustLevel) async throws -> String
    func forget(factId: String) async throws -> Bool
    func proposePreferenceIfApplicable(utterance: String, trust: TrustLevel) async
}

public extension MemoryContextProvider {
    func proposePreferenceIfApplicable(utterance: String, trust: TrustLevel) async {}
}
