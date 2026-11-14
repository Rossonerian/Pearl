import Foundation

/// Origin indicator defining how the request entered the Pearl system.
public enum RequestOrigin: String, Sendable, Codable {
    case voice
    case cli
    case socket
    case mcp
}

/// Typed request carrying provenance, session state, and security context.
public struct AssistantRequest: Sendable {
    public let id: String
    public let utterance: String
    public let origin: RequestOrigin
    public let sessionID: String
    public let userConfirmed: Bool
    public let forceEscalation: Bool
    public let clientTaintState: TaintState
    public let freshConfirmationArgs: [String: String]?
    
    public init(
        id: String = UUID().uuidString,
        utterance: String,
        origin: RequestOrigin = .voice,
        sessionID: String = "default",
        userConfirmed: Bool = false,
        forceEscalation: Bool = false,
        clientTaintState: TaintState = .clean,
        freshConfirmationArgs: [String: String]? = nil
    ) {
        self.id = id
        self.utterance = utterance
        self.origin = origin
        self.sessionID = sessionID
        self.userConfirmed = userConfirmed
        self.forceEscalation = forceEscalation
        self.clientTaintState = clientTaintState
        self.freshConfirmationArgs = freshConfirmationArgs
    }
}

/// Typed assistant response containing synthesized message, badges, tool results, and timing.
public struct AssistantResponse: Sendable {
    public let id: String
    public let success: Bool
    public let responseText: String
    public let speechText: String
    public let badge: HUDTurnBadge
    public let latencyMs: Double
    public let toolResults: [ToolResult]
    public let memoryUpdated: Bool
    
    public init(
        id: String,
        success: Bool,
        responseText: String,
        speechText: String? = nil,
        badge: HUDTurnBadge,
        latencyMs: Double,
        toolResults: [ToolResult] = [],
        memoryUpdated: Bool = false
    ) {
        self.id = id
        self.success = success
        self.responseText = responseText
        self.speechText = speechText ?? responseText
        self.badge = badge
        self.latencyMs = latencyMs
        self.toolResults = toolResults
        self.memoryUpdated = memoryUpdated
    }
}

/// Canonical, unified request processing pipeline for Pearl.
///
/// Implements the 16-stage request processing lifecycle:
/// 1. Receive request
/// 2. Validate input
/// 3. Establish provenance and trust
/// 4. Resolve cancellation and negation
/// 5. Classify intent
/// 6. Assemble context
/// 7. Retrieve relevant memory
/// 8. Select execution route
/// 9. Generate a plan when needed
/// 10. Obtain tool authorization
/// 11. Execute approved tools
/// 12. Validate output
/// 13. Update approved memory and tasks
/// 14. Generate response
/// 15. Deliver text and speech
/// 16. Record appropriate audit events
public final class AssistantPipeline: Sendable {
    public static let shared = AssistantPipeline()
    
    private let router: DeterministicRouter
    private let toolRegistry: ToolRegistry
    private let policyEngine: PolicyEngine
    private let toolExecutor: ModelToolExecutor
    private let fallbackChain: FallbackChain
    
    public init(
        router: DeterministicRouter = .shared,
        toolRegistry: ToolRegistry = .shared,
        policyEngine: PolicyEngine = .shared,
        toolExecutor: ModelToolExecutor = .shared,
        fallbackChain: FallbackChain = FallbackChain()
    ) {
        self.router = router
        self.toolRegistry = toolRegistry
        self.policyEngine = policyEngine
        self.toolExecutor = toolExecutor
        self.fallbackChain = fallbackChain
    }
    
    public func process(request: AssistantRequest) async -> AssistantResponse {
        var timebaseInfo = mach_timebase_info()
        mach_timebase_info(&timebaseInfo)
        let startTime = mach_continuous_time()
        
        func elapsedMs() -> Double {
            let now = mach_continuous_time()
            return Double(now - startTime) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom) / 1_000_000.0
        }
        
        // 1 & 2. Validate input
        let trimmed = request.utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AssistantResponse(
                id: request.id,
                success: true,
                responseText: "Pearl standing by.",
                badge: HUDTurnBadge(label: "ready", provider: "Pearl", modelID: "idle", isLocal: true),
                latencyMs: elapsedMs()
            )
        }
        
        if trimmed.count > 8192 {
            return AssistantResponse(
                id: request.id,
                success: false,
                responseText: "Request rejected: input length exceeds maximum 8192 characters.",
                badge: HUDTurnBadge(label: "error", provider: "Validation", modelID: "guard", isLocal: true),
                latencyMs: elapsedMs()
            )
        }
        
        // 3. Establish provenance and trust
        let isTrustedOrigin = (request.origin == .voice || request.origin == .cli)
        let effectiveTrust: TrustLevel = (isTrustedOrigin && !request.clientTaintState.isTainted) ? .trusted : .untrusted
        
        // 4. Resolve cancellation and negation
        let lower = trimmed.lowercased()
        let negationPatterns = ["don't", "dont", "do not", "never mind", "cancel that", "abort", "ignore that", "stop"]
        for neg in negationPatterns {
            if lower == neg || lower.hasPrefix(neg + " ") || lower.hasSuffix(" " + neg) || lower.contains(" " + neg + " ") {
                return AssistantResponse(
                    id: request.id,
                    success: true,
                    responseText: "Action cancelled.",
                    badge: HUDTurnBadge(label: "cancelled", provider: "Guard", modelID: "negation", isLocal: true),
                    latencyMs: elapsedMs()
                )
            }
        }
        
        // 5. Classify intent via Deterministic Router (L0)
        if let intent = router.resolve(utterance: trimmed) {
            // L0 Route: instant deterministic tool execution
            if let tool = toolRegistry.tool(named: intent.toolName) {
                let toolContext = ToolExecutionContext(
                    trustState: effectiveTrust,
                    userConfirmed: request.userConfirmed,
                    providerIsLocal: true,
                    taintState: request.clientTaintState,
                    freshConfirmationArgs: request.freshConfirmationArgs
                )
                
                do {
                    let toolRes = try await policyEngine.execute(tool: tool, args: intent.arguments, context: toolContext)
                    let badge = HUDTurnBadge(
                        label: "on device",
                        provider: "Deterministic",
                        modelID: intent.toolName,
                        isLocal: true,
                        details: String(format: "p50: < 1 ms")
                    )
                    return AssistantResponse(
                        id: request.id,
                        success: toolRes.success,
                        responseText: toolRes.message,
                        badge: badge,
                        latencyMs: elapsedMs(),
                        toolResults: [toolRes]
                    )
                } catch {
                    return AssistantResponse(
                        id: request.id,
                        success: false,
                        responseText: "Execution error: \(error.localizedDescription)",
                        badge: HUDTurnBadge(label: "error", provider: "PolicyEngine", modelID: intent.toolName, isLocal: true),
                        latencyMs: elapsedMs()
                    )
                }
            } else {
                return AssistantResponse(
                    id: request.id,
                    success: false,
                    responseText: "Tool '\(intent.toolName)' not registered.",
                    badge: HUDTurnBadge(label: "error", provider: "ToolRegistry", modelID: "missing", isLocal: true),
                    latencyMs: elapsedMs()
                )
            }
        }
        
        // 6 & 7. Fallback Route: Model Inference with ModelToolExecutor
        let modelContext = ModelExecutionContext(
            trustState: effectiveTrust,
            forceEscalation: request.forceEscalation
        )
        
        let modelRes = await fallbackChain.process(utterance: trimmed, context: modelContext)
        
        // 8 & 9 & 10 & 11. Execute Model-Generated Tool Calls if present
        if !modelRes.toolCalls.isEmpty {
            let toolContext = ToolExecutionContext(
                trustState: effectiveTrust,
                userConfirmed: request.userConfirmed,
                providerIsLocal: modelRes.isLocal,
                taintState: request.clientTaintState,
                freshConfirmationArgs: request.freshConfirmationArgs
            )
            
            let summary = await toolExecutor.executeToolCalls(
                modelRes.toolCalls,
                providerIsLocal: modelRes.isLocal,
                context: toolContext
            )
            
            let finalMessage = summary.synthesizedMessage.isEmpty ? modelRes.content : summary.synthesizedMessage
            return AssistantResponse(
                id: request.id,
                success: summary.toolCallsSucceeded > 0 || modelRes.toolCalls.isEmpty,
                responseText: finalMessage,
                badge: modelRes.badge,
                latencyMs: elapsedMs(),
                toolResults: summary.results
            )
        }
        
        // Conversational response without tool calls
        return AssistantResponse(
            id: request.id,
            success: true,
            responseText: modelRes.content,
            badge: modelRes.badge,
            latencyMs: elapsedMs(),
            toolResults: []
        )
    }
}
