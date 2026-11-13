import Foundation

public struct ModelToolCall: Sendable, Codable, Equatable {
    public let id: String
    public let toolName: String
    public let arguments: [String: String]
    
    public init(id: String = UUID().uuidString, toolName: String, arguments: [String: String]) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
    }
}

public struct TokenUsage: Sendable, Codable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public var totalTokens: Int { promptTokens + completionTokens }
    
    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public struct HUDTurnBadge: Sendable, Equatable, Codable {
    public let label: String
    public let provider: String
    public let modelID: String
    public let isLocal: Bool
    public let details: String?
    
    public init(
        label: String,
        provider: String,
        modelID: String,
        isLocal: Bool,
        details: String? = nil
    ) {
        self.label = label
        self.provider = provider
        self.modelID = modelID
        self.isLocal = isLocal
        self.details = details
    }
}

public struct ModelResponse: Sendable {
    public let content: String
    public let toolCalls: [ModelToolCall]
    public let usage: TokenUsage?
    public let providerName: String
    public let modelID: String
    public let isLocal: Bool
    public let badge: HUDTurnBadge
    
    public init(
        content: String,
        toolCalls: [ModelToolCall] = [],
        usage: TokenUsage? = nil,
        providerName: String,
        modelID: String,
        isLocal: Bool,
        badge: HUDTurnBadge? = nil
    ) {
        self.content = content
        self.toolCalls = toolCalls
        self.usage = usage
        self.providerName = providerName
        self.modelID = modelID
        self.isLocal = isLocal
        self.badge = badge ?? HUDTurnBadge(
            label: isLocal ? "on device" : "sent to \(providerName)",
            provider: providerName,
            modelID: modelID,
            isLocal: isLocal
        )
    }
}

public struct ModelExecutionContext: Sendable {
    public let systemPrompt: String?
    public let maxTokens: Int?
    public let temperature: Double?
    public let trustState: TrustLevel
    public let forceEscalation: Bool
    
    public init(
        systemPrompt: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        trustState: TrustLevel = .trusted,
        forceEscalation: Bool = false
    ) {
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.trustState = trustState
        self.forceEscalation = forceEscalation
    }
}

public enum ModelTierError: LocalizedError, Sendable, Equatable {
    case localModelTierViolation(tool: String, tier: ToolTier)
    case toolNotFound(String)
    case escalationRequired(tool: String, tier: ToolTier)
    
    public var errorDescription: String? {
        switch self {
        case .localModelTierViolation(let tool, let tier):
            return "Security violation: On-device local model is restricted to T0-T2 tools, but attempted to execute \(tool) (\(tier)). Escalation or user confirmation required."
        case .toolNotFound(let name):
            return "Tool '\(name)' not found in registry."
        case .escalationRequired(let tool, let tier):
            return "Action \(tool) requires frontier model escalation (Tier \(tier))."
        }
    }
}

public struct ToolTierEnforcer {
    /// Strictly verifies that local models only invoke T0-T2 tools.
    /// The model NEVER picks its own tier: the registered tool's tier from ToolRegistry is strictly used.
    public static func validateToolCall(
        _ toolCall: ModelToolCall,
        providerIsLocal: Bool,
        registry: ToolRegistry = .shared
    ) throws -> any PearlTool {
        guard let tool = registry.tool(named: toolCall.toolName) else {
            throw ModelTierError.toolNotFound(toolCall.toolName)
        }
        
        if providerIsLocal && tool.tier > .t2ReadPersonal {
            throw ModelTierError.localModelTierViolation(tool: tool.name, tier: tool.tier)
        }
        
        return tool
    }
}

public protocol ModelProvider: Sendable {
    var name: String { get }
    var modelID: String { get }
    var isLocal: Bool { get }
    var maxAllowedTier: ToolTier { get }
    
    func generate(prompt: String, context: ModelExecutionContext) async throws -> ModelResponse
    func stream(prompt: String, context: ModelExecutionContext) -> AsyncThrowingStream<String, Error>
}
