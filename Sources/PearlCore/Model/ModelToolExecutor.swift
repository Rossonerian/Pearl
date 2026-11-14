import Foundation

/// Summary of executed model-proposed tool calls within a single conversational turn.
public struct ModelToolExecutionSummary: Sendable {
    public let toolCallsAttempted: Int
    public let toolCallsSucceeded: Int
    public let results: [ToolResult]
    public let synthesizedMessage: String
    
    public init(toolCallsAttempted: Int, toolCallsSucceeded: Int, results: [ToolResult], synthesizedMessage: String) {
        self.toolCallsAttempted = toolCallsAttempted
        self.toolCallsSucceeded = toolCallsSucceeded
        self.results = results
        self.synthesizedMessage = synthesizedMessage
    }
}

public enum ModelToolExecutionError: LocalizedError, Sendable {
    case maxCallsExceeded(limit: Int)
    case toolNotFound(String)
    case localModelTierViolation(tool: String, tier: ToolTier)
    case executionTimeout(tool: String, seconds: Double)
    case argumentValidationFailed(tool: String, reason: String)
    
    public var errorDescription: String? {
        switch self {
        case .maxCallsExceeded(let limit):
            return "Tool call limit of \(limit) per turn exceeded."
        case .toolNotFound(let name):
            return "Tool '\(name)' not registered in ToolRegistry."
        case .localModelTierViolation(let tool, let tier):
            return "Local model tier violation: '\(tool)' is classified as \(tier) (limit is T2)."
        case .executionTimeout(let tool, let s):
            return "Tool '\(tool)' execution timed out after \(s) seconds."
        case .argumentValidationFailed(let tool, let reason):
            return "Argument validation failed for '\(tool)': \(reason)"
        }
    }
}

/// Centralized executor that consumes, validates, authorizes, and runs
/// model-generated tool calls (`ModelResponse.toolCalls`) from Apple FM or Frontier models.
public final class ModelToolExecutor: Sendable {
    public static let shared = ModelToolExecutor()
    public static let maxToolCallsPerTurn = 3
    
    private let registry: ToolRegistry
    private let policyEngine: PolicyEngine
    private let catalog: CentralToolCatalog
    
    public init(
        registry: ToolRegistry = .shared,
        policyEngine: PolicyEngine = .shared,
        catalog: CentralToolCatalog = .shared
    ) {
        self.registry = registry
        self.policyEngine = policyEngine
        self.catalog = catalog
    }
    
    /// Validates and executes a sequence of model-proposed tool calls.
    ///
    /// - Parameters:
    ///   - toolCalls: Array of tool calls emitted by the model.
    ///   - providerIsLocal: Whether the calling model is an on-device local model (e.g. Apple FM).
    ///   - context: Execution context with trust and confirmation states.
    /// - Returns: `ModelToolExecutionSummary` containing executed results and final message.
    public func executeToolCalls(
        _ toolCalls: [ModelToolCall],
        providerIsLocal: Bool,
        context: ToolExecutionContext
    ) async -> ModelToolExecutionSummary {
        guard !toolCalls.isEmpty else {
            return ModelToolExecutionSummary(
                toolCallsAttempted: 0,
                toolCallsSucceeded: 0,
                results: [],
                synthesizedMessage: ""
            )
        }
        
        var results: [ToolResult] = []
        var messages: [String] = []
        var succeededCount = 0
        
        // Strictly bound maximum number of tool calls per turn to prevent recursive loops
        let callsToExecute = Array(toolCalls.prefix(Self.maxToolCallsPerTurn))
        let excessCalls = toolCalls.count - callsToExecute.count
        
        for call in callsToExecute {
            // 1. Look up tool in registry / catalog
            guard let tool = registry.tool(named: call.toolName) ?? catalog.tool(named: call.toolName) else {
                let failure = ToolResult(
                    success: false,
                    message: "Tool '\(call.toolName)' is not registered.",
                    trust: context.trustState
                )
                results.append(failure)
                messages.append(failure.message)
                continue
            }
            
            // 2. Validate provider tier boundary: on-device local models can ONLY call T0-T2 tools
            if providerIsLocal && tool.tier > .t2ReadPersonal {
                let tierMsg = "Security policy: Local model cannot execute '\(tool.name)' (Tier \(tool.tier.rawValue)). Escalation or user confirmation required."
                let failure = ToolResult(
                    success: false,
                    message: tierMsg,
                    trust: context.trustState
                )
                results.append(failure)
                messages.append(tierMsg)
                continue
            }
            
            // 3. Validate typed arguments against descriptors
            var validationError: String? = nil
            for desc in tool.argumentDescriptors {
                if desc.isRequired && (call.arguments[desc.name] == nil || call.arguments[desc.name]!.isEmpty) {
                    validationError = "Missing required argument '\(desc.name)'"
                    break
                }
                if let allowed = desc.allowedValues, let val = call.arguments[desc.name] {
                    if !allowed.contains(val) {
                        validationError = "Invalid value '\(val)' for argument '\(desc.name)'. Allowed: \(allowed)"
                        break
                    }
                }
            }
            
            if let err = validationError {
                let failure = ToolResult(
                    success: false,
                    message: "Validation failed for '\(tool.name)': \(err)",
                    trust: context.trustState
                )
                results.append(failure)
                messages.append(failure.message)
                continue
            }
            
            // 4. Execute tool via PolicyEngine with timeout
            let timeoutSeconds = catalog.metadata(for: tool.name)?.timeoutSeconds ?? 15.0
            let effectiveContext = ToolExecutionContext(
                trustState: context.trustState,
                userConfirmed: context.userConfirmed,
                providerIsLocal: providerIsLocal,
                taintState: context.taintState,
                freshConfirmationArgs: context.freshConfirmationArgs
            )
            
            do {
                let result = try await withTimeout(seconds: timeoutSeconds) {
                    try await self.policyEngine.execute(tool: tool, args: call.arguments, context: effectiveContext)
                }
                results.append(result)
                messages.append(result.message)
                if result.success {
                    succeededCount += 1
                }
            } catch {
                let failure = ToolResult(
                    success: false,
                    message: "Tool '\(tool.name)' failed: \(error.localizedDescription)",
                    trust: context.trustState
                )
                results.append(failure)
                messages.append(failure.message)
            }
        }
        
        if excessCalls > 0 {
            messages.append("Note: \(excessCalls) additional tool call(s) dropped (turn limit: \(Self.maxToolCallsPerTurn)).")
        }
        
        let finalMessage = messages.joined(separator: "\n")
        return ModelToolExecutionSummary(
            toolCallsAttempted: toolCalls.count,
            toolCallsSucceeded: succeededCount,
            results: results,
            synthesizedMessage: finalMessage
        )
    }
    
    private func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ModelToolExecutionError.executionTimeout(tool: "operation", seconds: seconds)
            }
            
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
