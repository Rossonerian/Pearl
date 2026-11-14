import Foundation

/// Detailed execution record for a tool call made during a conversation turn.
public struct ToolExecutionRecord: Sendable, Codable, Equatable {
    public let toolName: String
    public let arguments: [String: String]
    public let success: Bool
    public let resultMessage: String
    public let durationMs: Double
    public let timestamp: Date
    
    public init(
        toolName: String,
        arguments: [String: String] = [:],
        success: Bool = true,
        resultMessage: String = "",
        durationMs: Double = 0.0,
        timestamp: Date = Date()
    ) {
        self.toolName = toolName
        self.arguments = arguments
        self.success = success
        self.resultMessage = resultMessage
        self.durationMs = durationMs
        self.timestamp = timestamp
    }
}

/// Typed representation of a single conversational turn in Pearl.
public struct ConversationTurn: Sendable, Codable, Identifiable, Equatable {
    public var id: UUID { turnId }
    public let turnId: UUID
    public let timestamp: Date
    public let rawInput: String
    public let cleanedInput: String
    public let resolvedIntent: ResolvedIntent?
    public let toolInvocations: [ToolExecutionRecord]
    public let assistantResponse: String
    public let tokenUsage: TokenUsage?
    public let latencyMs: Double
    
    public init(
        turnId: UUID = UUID(),
        timestamp: Date = Date(),
        rawInput: String,
        cleanedInput: String,
        resolvedIntent: ResolvedIntent? = nil,
        toolInvocations: [ToolExecutionRecord] = [],
        assistantResponse: String,
        tokenUsage: TokenUsage? = nil,
        latencyMs: Double = 0.0
    ) {
        self.turnId = turnId
        self.timestamp = timestamp
        self.rawInput = rawInput
        self.cleanedInput = cleanedInput
        self.resolvedIntent = resolvedIntent
        self.toolInvocations = toolInvocations
        self.assistantResponse = assistantResponse
        self.tokenUsage = tokenUsage
        self.latencyMs = latencyMs
    }
    
    /// Estimated token footprint of this turn for context window budget management.
    public var estimatedTokens: Int {
        if let usage = tokenUsage {
            return usage.totalTokens
        }
        // Heuristic: ~4 characters per token + tool call overhead
        let inputTokens = max(1, rawInput.utf8.count / 4)
        let responseTokens = max(1, assistantResponse.utf8.count / 4)
        let toolTokens = toolInvocations.reduce(0) { sum, inv in
            sum + 15 + inv.toolName.count / 4 + inv.resultMessage.count / 4
        }
        return inputTokens + responseTokens + toolTokens
    }
}
