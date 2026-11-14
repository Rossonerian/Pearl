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
    public let outputDecision: OutputDecision?
    
    public init(
        id: String,
        success: Bool,
        responseText: String,
        speechText: String? = nil,
        badge: HUDTurnBadge,
        latencyMs: Double,
        toolResults: [ToolResult] = [],
        memoryUpdated: Bool = false,
        outputDecision: OutputDecision? = nil
    ) {
        self.id = id
        self.success = success
        self.responseText = responseText
        self.speechText = speechText ?? responseText
        self.badge = badge
        self.latencyMs = latencyMs
        self.toolResults = toolResults
        self.memoryUpdated = memoryUpdated
        self.outputDecision = outputDecision
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
public final class AssistantPipeline: @unchecked Sendable {
    public static let shared = AssistantPipeline()
    
    private let router: DeterministicRouter
    private let toolRegistry: ToolRegistry
    private let policyEngine: PolicyEngine
    private let toolExecutor: ModelToolExecutor
    private let fallbackChain: FallbackChain
    public let sessionManager: SessionManager
    public let referenceResolver: ContextReferenceResolver
    
    private let lock = NSLock()
    private var _memoryProvider: (any MemoryContextProvider)?
    
    public var memoryProvider: (any MemoryContextProvider)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _memoryProvider
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _memoryProvider = newValue
        }
    }
    
    public init(
        router: DeterministicRouter = .shared,
        toolRegistry: ToolRegistry = .shared,
        policyEngine: PolicyEngine = .shared,
        toolExecutor: ModelToolExecutor = .shared,
        fallbackChain: FallbackChain = FallbackChain(),
        sessionManager: SessionManager = .shared,
        referenceResolver: ContextReferenceResolver = ContextReferenceResolver()
    ) {
        self.router = router
        self.toolRegistry = toolRegistry
        self.policyEngine = policyEngine
        self.toolExecutor = toolExecutor
        self.fallbackChain = fallbackChain
        self.sessionManager = sessionManager
        self.referenceResolver = referenceResolver
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
            let decision = OutputDirector.shared.decide(
                responseText: "Pearl standing by.",
                origin: request.origin
            )
            return AssistantResponse(
                id: request.id,
                success: true,
                responseText: "Pearl standing by.",
                speechText: decision.spokenText ?? "",
                badge: HUDTurnBadge(label: "ready", provider: "Pearl", modelID: "idle", isLocal: true),
                latencyMs: elapsedMs(),
                outputDecision: decision
            )
        }
        
        if trimmed.count > 8192 {
            let resp = "Request rejected: input length exceeds maximum 8192 characters."
            let decision = OutputDirector.shared.decide(
                responseText: resp,
                origin: request.origin,
                isError: true
            )
            return AssistantResponse(
                id: request.id,
                success: false,
                responseText: resp,
                speechText: decision.spokenText ?? "",
                badge: HUDTurnBadge(label: "error", provider: "Validation", modelID: "guard", isLocal: true),
                latencyMs: elapsedMs(),
                outputDecision: decision
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
                let resp = "Action cancelled."
                let decision = OutputDirector.shared.decide(
                    responseText: resp,
                    origin: request.origin
                )
                return AssistantResponse(
                    id: request.id,
                    success: true,
                    responseText: resp,
                    speechText: decision.spokenText ?? "",
                    badge: HUDTurnBadge(label: "cancelled", provider: "Guard", modelID: "negation", isLocal: true),
                    latencyMs: elapsedMs(),
                    outputDecision: decision
                )
            }
        }
        
        // 5. Memory Operations (Explicit Remember)
        if let memoryFact = extractExplicitMemoryFact(from: trimmed) {
            if let provider = memoryProvider {
                do {
                    let factId = try await provider.explicitRemember(fact: memoryFact, trust: effectiveTrust)
                    let badge = HUDTurnBadge(
                        label: "remembered",
                        provider: "MemoryStore",
                        modelID: "explicit",
                        isLocal: true,
                        details: "id: \(factId)"
                    )
                    let duration = elapsedMs()
                    let turn = ConversationTurn(
                        turnId: UUID(),
                        timestamp: Date(),
                        rawInput: request.utterance,
                        cleanedInput: trimmed,
                        resolvedIntent: nil,
                        toolInvocations: [],
                        assistantResponse: "Remembered: '\(memoryFact)'.",
                        tokenUsage: nil,
                        latencyMs: duration
                    )
                    await sessionManager.recordTurn(turn, sessionID: request.sessionID)
                    let resp = "Remembered: '\(memoryFact)'."
                    let decision = OutputDirector.shared.decide(
                        responseText: resp,
                        origin: request.origin
                    )
                    return AssistantResponse(
                        id: request.id,
                        success: true,
                        responseText: resp,
                        speechText: decision.spokenText ?? "",
                        badge: badge,
                        latencyMs: duration,
                        memoryUpdated: true,
                        outputDecision: decision
                    )
                } catch {
                    let duration = elapsedMs()
                    let resp = "Could not save fact: \(error.localizedDescription)"
                    let decision = OutputDirector.shared.decide(
                        responseText: resp,
                        origin: request.origin,
                        isError: true
                    )
                    return AssistantResponse(
                        id: request.id,
                        success: false,
                        responseText: resp,
                        speechText: decision.spokenText ?? "",
                        badge: HUDTurnBadge(label: "error", provider: "MemoryStore", modelID: "gate", isLocal: true),
                        latencyMs: duration,
                        outputDecision: decision
                    )
                }
            }
        }
        
        // 5.5. Contextual Reference Resolution
        var effectiveUtterance = trimmed
        var preResolvedIntent: ResolvedIntent? = nil
        
        if referenceResolver.containsAnaphora(trimmed) {
            let recentTurns = await sessionManager.getRecentTurns(sessionID: request.sessionID)
            let resolution = referenceResolver.resolve(utterance: trimmed, history: recentTurns)
            if resolution.didResolve {
                effectiveUtterance = resolution.resolvedUtterance
                preResolvedIntent = resolution.resolvedIntent
            }
        }
        
        // 6. Classify intent via Deterministic Router (L0)
        let intent = preResolvedIntent ?? router.resolve(utterance: effectiveUtterance)
        if let intent = intent {
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
                    let duration = elapsedMs()
                    let toolRecord = ToolExecutionRecord(
                        toolName: intent.toolName,
                        arguments: intent.arguments,
                        success: toolRes.success,
                        resultMessage: toolRes.message,
                        durationMs: duration
                    )
                    let turn = ConversationTurn(
                        turnId: UUID(),
                        timestamp: Date(),
                        rawInput: request.utterance,
                        cleanedInput: effectiveUtterance,
                        resolvedIntent: intent,
                        toolInvocations: [toolRecord],
                        assistantResponse: toolRes.message,
                        tokenUsage: nil,
                        latencyMs: duration
                    )
                    await sessionManager.recordTurn(turn, sessionID: request.sessionID)
                    
                    let isConfirmation = toolRes.message.localizedCaseInsensitiveContains("confirmation required") ||
                                         toolRes.message.localizedCaseInsensitiveContains("user confirmation required")
                    let decision = OutputDirector.shared.decide(
                        responseText: toolRes.message,
                        origin: request.origin,
                        isError: !toolRes.success && !isConfirmation,
                        requiresConfirmation: isConfirmation
                    )
                    
                    return AssistantResponse(
                        id: request.id,
                        success: toolRes.success,
                        responseText: toolRes.message,
                        speechText: decision.spokenText ?? "",
                        badge: badge,
                        latencyMs: duration,
                        toolResults: [toolRes],
                        outputDecision: decision
                    )
                } catch {
                    let duration = elapsedMs()
                    let errorTurn = ConversationTurn(
                        turnId: UUID(),
                        timestamp: Date(),
                        rawInput: request.utterance,
                        cleanedInput: effectiveUtterance,
                        resolvedIntent: intent,
                        toolInvocations: [],
                        assistantResponse: "Execution error: \(error.localizedDescription)",
                        tokenUsage: nil,
                        latencyMs: duration
                    )
                    await sessionManager.recordTurn(errorTurn, sessionID: request.sessionID)
                    
                    let errorMsg = "Execution error: \(error.localizedDescription)"
                    let decision = OutputDirector.shared.decide(
                        responseText: errorMsg,
                        origin: request.origin,
                        isError: true
                    )
                    return AssistantResponse(
                        id: request.id,
                        success: false,
                        responseText: errorMsg,
                        speechText: decision.spokenText ?? "",
                        badge: HUDTurnBadge(label: "error", provider: "PolicyEngine", modelID: intent.toolName, isLocal: true),
                        latencyMs: duration,
                        outputDecision: decision
                    )
                }
            } else {
                let duration = elapsedMs()
                let errorMsg = "Tool '\(intent.toolName)' not registered."
                let decision = OutputDirector.shared.decide(
                    responseText: errorMsg,
                    origin: request.origin,
                    isError: true
                )
                return AssistantResponse(
                    id: request.id,
                    success: false,
                    responseText: errorMsg,
                    speechText: decision.spokenText ?? "",
                    badge: HUDTurnBadge(label: "error", provider: "ToolRegistry", modelID: "missing", isLocal: true),
                    latencyMs: duration,
                    outputDecision: decision
                )
            }
        }
        
        // 7. Dynamic Context Assembly & Memory Retrieval
        var memorySection: String? = nil
        if let provider = memoryProvider {
            memorySection = try? await provider.assembleContext(query: effectiveUtterance)
        }
        
        let boundedHistory = await sessionManager.getBoundedHistory(sessionID: request.sessionID)
        let modelContext = ModelExecutionContext(
            systemPrompt: memorySection,
            trustState: effectiveTrust,
            forceEscalation: request.forceEscalation,
            conversationHistory: boundedHistory
        )
        
        // 8. Fallback Route: Model Inference with ModelToolExecutor
        let modelRes = await fallbackChain.process(utterance: effectiveUtterance, context: modelContext)
        
        // 9 & 10 & 11. Execute Model-Generated Tool Calls if present
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
            let duration = elapsedMs()
            let toolRecords = summary.results.enumerated().map { (idx, res) in
                let call = idx < modelRes.toolCalls.count ? modelRes.toolCalls[idx] : nil
                return ToolExecutionRecord(
                    toolName: call?.toolName ?? "tool",
                    arguments: call?.arguments ?? [:],
                    success: res.success,
                    resultMessage: res.message,
                    durationMs: duration
                )
            }
            let turn = ConversationTurn(
                turnId: UUID(),
                timestamp: Date(),
                rawInput: request.utterance,
                cleanedInput: effectiveUtterance,
                resolvedIntent: nil,
                toolInvocations: toolRecords,
                assistantResponse: finalMessage,
                tokenUsage: modelRes.usage,
                latencyMs: duration
            )
            await sessionManager.recordTurn(turn, sessionID: request.sessionID)
            
            let isConfirmation = finalMessage.localizedCaseInsensitiveContains("confirmation required") ||
                                 finalMessage.localizedCaseInsensitiveContains("user confirmation required") ||
                                 summary.results.contains { $0.message.localizedCaseInsensitiveContains("confirmation required") }
            let decision = OutputDirector.shared.decide(
                responseText: finalMessage,
                origin: request.origin,
                isError: summary.toolCallsSucceeded == 0 && !modelRes.toolCalls.isEmpty && !isConfirmation,
                requiresConfirmation: isConfirmation
            )
            
            return AssistantResponse(
                id: request.id,
                success: summary.toolCallsSucceeded > 0 || modelRes.toolCalls.isEmpty,
                responseText: finalMessage,
                speechText: decision.spokenText ?? "",
                badge: modelRes.badge,
                latencyMs: duration,
                toolResults: summary.results,
                outputDecision: decision
            )
        }
        
        // Conversational response without tool calls
        let duration = elapsedMs()
        let turn = ConversationTurn(
            turnId: UUID(),
            timestamp: Date(),
            rawInput: request.utterance,
            cleanedInput: effectiveUtterance,
            resolvedIntent: nil,
            toolInvocations: [],
            assistantResponse: modelRes.content,
            tokenUsage: modelRes.usage,
            latencyMs: duration
        )
        await sessionManager.recordTurn(turn, sessionID: request.sessionID)
        
        let isConfirmation = modelRes.content.localizedCaseInsensitiveContains("confirmation required") ||
                             modelRes.content.localizedCaseInsensitiveContains("user confirmation required")
        let decision = OutputDirector.shared.decide(
            responseText: modelRes.content,
            origin: request.origin,
            requiresConfirmation: isConfirmation
        )
        
        return AssistantResponse(
            id: request.id,
            success: true,
            responseText: modelRes.content,
            speechText: decision.spokenText ?? "",
            badge: modelRes.badge,
            latencyMs: duration,
            toolResults: [],
            outputDecision: decision
        )
    }
    
    private func extractExplicitMemoryFact(from text: String) -> String? {
        let lower = text.lowercased()
        let prefixes = [
            "remember that ", "remember this: ", "remember: ", "remember ",
            "pearl remember that ", "pearl remember ", "please remember that ", "please remember "
        ]
        for p in prefixes {
            if lower.hasPrefix(p) {
                let fact = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !fact.isEmpty && fact.count <= 500 {
                    return fact
                }
            }
        }
        return nil
    }
}
