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
    public let requiresConfirmation: Bool
    public let confirmationToolName: String?
    public let confirmationArguments: [String: String]?
    public let confirmationReason: String?
    public let needsClarification: Bool
    
    public init(
        id: String,
        success: Bool,
        responseText: String,
        speechText: String? = nil,
        badge: HUDTurnBadge,
        latencyMs: Double,
        toolResults: [ToolResult] = [],
        memoryUpdated: Bool = false,
        outputDecision: OutputDecision? = nil,
        requiresConfirmation: Bool = false,
        confirmationToolName: String? = nil,
        confirmationArguments: [String: String]? = nil,
        confirmationReason: String? = nil,
        needsClarification: Bool = false
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
        self.requiresConfirmation = requiresConfirmation
        self.confirmationToolName = confirmationToolName
        self.confirmationArguments = confirmationArguments
        self.confirmationReason = confirmationReason
        self.needsClarification = needsClarification
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
        
        let response = await processCore(request: request, elapsedMs: elapsedMs)
        PerformanceMonitor.shared.record(operation: "pipeline.process", durationMs: response.latencyMs)
        return response
    }
    
    private func processCore(request: AssistantRequest, elapsedMs: () -> Double) async -> AssistantResponse {
        
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
        let negationPatterns = ["don't", "dont", "do not", "never mind", "cancel that", "cancel it", "abort", "ignore that", "stop"]
        let isExactCancel = (lower == "cancel" || lower == "no" || lower == "nope")
        let isMatchedNegation = negationPatterns.contains { neg in
            lower == neg || lower.hasPrefix(neg + " ") || lower.hasSuffix(" " + neg) || lower.contains(" " + neg + " ")
        }
        if isExactCancel || isMatchedNegation {
            await sessionManager.clearPendingClarification(sessionID: request.sessionID)
            if lower.contains("abort") || lower.contains("stop") || lower.contains("cancel that") {
                KillSwitch.shared.trigger(reason: "User verbal cancellation: '\(trimmed)'")
            }
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
        
        // 5.4. Specialist Archetype Prefix Detection (@athena, @artemis, @mnemosyne, @sisyphus)
        let parsedArchetype = SpecialistArchetype.parsePrefix(from: trimmed)
        let activeArchetype = parsedArchetype?.archetype
        let archetypeQuery = parsedArchetype?.strippedQuery ?? trimmed
        if let arch = activeArchetype, archetypeQuery.isEmpty {
            return finalizeResponse(
                text: "Specialist \(arch.displayName) standing by (\(arch.domain)). Provide a goal after @\(arch.rawValue).",
                request: request,
                badge: HUDTurnBadge(label: arch.rawValue, provider: "Archetype", modelID: arch.displayName, isLocal: true),
                latencyMs: elapsedMs()
            )
        }
        
        // 5.5. Pending Clarification Follow-up & Contextual Reference Resolution
        var effectiveUtterance = archetypeQuery
        var preResolvedIntent: ResolvedIntent? = nil
        
        if let pending = await sessionManager.getPendingClarification(sessionID: request.sessionID) {
            if let resolvedDir = router.resolveKnownDirectory(from: archetypeQuery) {
                await sessionManager.clearPendingClarification(sessionID: request.sessionID)
                if pending.kind == "create_directory" || pending.kind == "create_directories" {
                    let steps = pending.targets.map { name -> ResolvedPlanStep in
                        let path = (name.hasPrefix("~/") || name.hasPrefix("/"))
                            ? name
                            : (resolvedDir as NSString).appendingPathComponent(name)
                        return ResolvedPlanStep(
                            toolName: "create_directory",
                            arguments: ["path": path, "recursive": "false", "create_if_missing": "false"],
                            description: "Create folder \((path as NSString).lastPathComponent) in \(resolvedDir)"
                        )
                    }
                    if steps.count == 1 {
                        preResolvedIntent = ResolvedIntent(
                            toolName: steps[0].toolName,
                            arguments: steps[0].arguments,
                            confidence: 0.99
                        )
                    } else if steps.count > 1 {
                        preResolvedIntent = ResolvedIntent(
                            toolName: "create_directory",
                            arguments: steps[0].arguments,
                            confidence: 0.99,
                            planSteps: steps
                        )
                    }
                } else if pending.kind == "rename_source",
                          let sourceName = pending.targets.first,
                          let newName = pending.newName {
                    let srcPath = (resolvedDir as NSString).appendingPathComponent(sourceName)
                    let dstPath = (newName.hasPrefix("/") || newName.hasPrefix("~/"))
                        ? newName
                        : (resolvedDir as NSString).appendingPathComponent(newName)
                    preResolvedIntent = ResolvedIntent(
                        toolName: "rename_file",
                        arguments: ["source": srcPath, "destination": dstPath],
                        confidence: 0.98
                    )
                }
            } else {
                // User switched topic rather than answering clarification
                await sessionManager.clearPendingClarification(sessionID: request.sessionID)
            }
        }
        
        if preResolvedIntent == nil, referenceResolver.containsAnaphora(archetypeQuery) {
            let recentTurns = await sessionManager.getRecentTurns(sessionID: request.sessionID)
            let resolution = referenceResolver.resolve(utterance: archetypeQuery, history: recentTurns)
            if resolution.didResolve {
                effectiveUtterance = resolution.resolvedUtterance
                preResolvedIntent = resolution.resolvedIntent
            }
        }
        
        // 5.7. Declarative Markdown Skills (O(1) Inverted Index) & Recipes
        await SkillEngine.shared.ensureSeeded()
        RecipeEngine.shared.ensureSeeded()
        let skillMatch = await SkillEngine.shared.findSkillByTrigger(effectiveUtterance)
        if let exactSkill = skillMatch, exactSkill.score >= 1.0 {
            return await executeMatchedSkill(
                exactSkill.skill,
                request: request,
                effectiveUtterance: effectiveUtterance,
                effectiveTrust: effectiveTrust,
                archetype: activeArchetype,
                elapsedMs: elapsedMs
            )
        }
        if let matchedRecipe = RecipeEngine.shared.matchRecipe(for: effectiveUtterance) {
            return await handleMatchedRecipe(
                matchedRecipe,
                request: request,
                effectiveUtterance: effectiveUtterance,
                elapsedMs: elapsedMs
            )
        }
        
        // 6. Classify intent via Deterministic Router (L0)
        var intent = preResolvedIntent ?? router.resolve(utterance: effectiveUtterance)
        if let rawIntent = intent {
            // Disambiguate bare filenames for rename/move/trash against recent session context or approved folders without guessing
            if let disambiguated = await disambiguateFilesystemIntent(rawIntent, request: request, elapsedMs: elapsedMs) {
                switch disambiguated {
                case .resolved(let updated):
                    intent = updated
                case .earlyResponse(let response):
                    return response
                }
            }
        }
        if let intent = intent {
            if let builtInResponse = await handleBuiltInIntent(
                intent,
                request: request,
                effectiveUtterance: effectiveUtterance,
                elapsedMs: elapsedMs
            ) {
                return builtInResponse
            }
            
            // Multi-step deterministic plan (e.g. "Create three folders named Backend, Frontend and Documentation on Desktop")
            if let planSteps = intent.planSteps, planSteps.count > 1 {
                KillSwitch.shared.reset()
                let executor = effectivePlanExecutor()
                let steps = planSteps.enumerated().map { idx, ps in
                    let registeredTool = lookupTool(named: ps.toolName)
                    return PlanStep(
                        index: idx,
                        description: ps.description.isEmpty ? ps.toolName : ps.description,
                        toolName: ps.toolName,
                        arguments: ps.arguments,
                        status: .pending,
                        resultMessage: nil,
                        reversible: registeredTool?.isReversible ?? false
                    )
                }
                let toolContext = ToolExecutionContext(
                    trustState: effectiveTrust,
                    userConfirmed: request.userConfirmed,
                    providerIsLocal: true,
                    taintState: request.clientTaintState,
                    freshConfirmationArgs: request.freshConfirmationArgs
                )
                do {
                    let job = try await executor.executePlan(
                        goal: effectiveUtterance,
                        steps: steps,
                        context: toolContext,
                        archetype: activeArchetype
                    )
                    let duration = elapsedMs()
                    let summaryMsg = job.steps.map { "• [\($0.status.rawValue)] \($0.toolName): \($0.resultMessage ?? "")" }.joined(separator: "\n")
                    let isConfirmation = job.status == .pausedForApproval
                    let finalMsg = isConfirmation
                        ? "Confirmation required for multi-step plan '\(job.goal)' (Job \(String(job.id.prefix(8))))."
                        : summaryMsg
                    let records = job.steps.map { step in
                        ToolExecutionRecord(
                            toolName: step.toolName,
                            arguments: step.arguments,
                            success: step.status == .completed,
                            resultMessage: step.resultMessage ?? "",
                            durationMs: duration
                        )
                    }
                    let turn = ConversationTurn(
                        turnId: UUID(),
                        timestamp: Date(),
                        rawInput: request.utterance,
                        cleanedInput: effectiveUtterance,
                        resolvedIntent: intent,
                        toolInvocations: records,
                        assistantResponse: finalMsg,
                        tokenUsage: nil,
                        latencyMs: duration
                    )
                    await sessionManager.recordTurn(turn, sessionID: request.sessionID)
                    let badge = HUDTurnBadge(
                        label: activeArchetype?.rawValue ?? "",
                        provider: "Deterministic",
                        modelID: "multi-step(\(steps.count))",
                        isLocal: true,
                        details: String(format: "%.1f ms", duration)
                    )
                    let pausedStep = isConfirmation ? job.steps.first(where: { $0.status == .pausedForApproval }) : nil
                    return finalizeResponse(
                        text: finalMsg,
                        request: request,
                        badge: badge,
                        latencyMs: duration,
                        success: job.status == .completed,
                        isConfirmation: isConfirmation,
                        confirmationToolName: pausedStep?.toolName,
                        confirmationArguments: pausedStep?.arguments,
                        confirmationReason: isConfirmation ? pausedStep?.resultMessage : nil
                    )
                } catch {
                    return finalizeResponse(
                        text: "Multi-step execution failed: \(error.localizedDescription)",
                        request: request,
                        badge: HUDTurnBadge(label: "error", provider: "PlanExecutor", modelID: intent.toolName, isLocal: true),
                        latencyMs: elapsedMs(),
                        success: false
                    )
                }
            }
            
            if let tool = lookupTool(named: intent.toolName) {
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
                        label: activeArchetype?.rawValue ?? "",
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
                    
                    let isConfirmation = !toolRes.success && (
                        toolRes.message.localizedCaseInsensitiveContains("confirmation required") ||
                        toolRes.message.localizedCaseInsensitiveContains("user confirmation required")
                    )
                    return finalizeResponse(
                        text: toolRes.message,
                        request: request,
                        badge: badge,
                        latencyMs: duration,
                        success: toolRes.success,
                        isConfirmation: isConfirmation,
                        toolResults: [toolRes],
                        confirmationToolName: isConfirmation ? intent.toolName : nil,
                        confirmationArguments: isConfirmation ? intent.arguments : nil,
                        confirmationReason: isConfirmation ? toolRes.message : nil
                    )
                } catch {
                    let duration = elapsedMs()
                    let errorMsg = "Execution error: \(error.localizedDescription)"
                    let errorTurn = ConversationTurn(
                        turnId: UUID(),
                        timestamp: Date(),
                        rawInput: request.utterance,
                        cleanedInput: effectiveUtterance,
                        resolvedIntent: intent,
                        toolInvocations: [],
                        assistantResponse: errorMsg,
                        tokenUsage: nil,
                        latencyMs: duration
                    )
                    await sessionManager.recordTurn(errorTurn, sessionID: request.sessionID)
                    return finalizeResponse(
                        text: errorMsg,
                        request: request,
                        badge: HUDTurnBadge(label: "error", provider: "PolicyEngine", modelID: intent.toolName, isLocal: true),
                        latencyMs: duration,
                        success: false
                    )
                }
            } else {
                let metaExists = CentralToolCatalog.shared.metadata(for: intent.toolName) != nil
                let msg = metaExists
                    ? "Tool '\(intent.toolName)' is defined in catalog metadata but not implemented or registered at runtime."
                    : "Tool '\(intent.toolName)' is not registered."
                return finalizeResponse(
                    text: msg,
                    request: request,
                    badge: HUDTurnBadge(label: "error", provider: "ToolRegistry", modelID: "missing", isLocal: true),
                    latencyMs: elapsedMs(),
                    success: false
                )
            }
        }
        
        // Fuzzy keyword skill overlap (when L0 router did not claim exact tool route)
        if let fuzzySkill = skillMatch {
            return await executeMatchedSkill(
                fuzzySkill.skill,
                request: request,
                effectiveUtterance: effectiveUtterance,
                effectiveTrust: effectiveTrust,
                archetype: activeArchetype,
                elapsedMs: elapsedMs
            )
        }
        
        // 7. Dynamic Context Assembly & Memory Retrieval
        var memorySection: String? = nil
        if let provider = memoryProvider {
            memorySection = try? await provider.assembleContext(query: effectiveUtterance)
        }
        
        var systemSections: [String] = [PersonaEngine.shared.systemPromptPrefix()]
        if let arch = activeArchetype {
            systemSections.append("[Specialist Mode: \(arch.displayName)]\n\(arch.systemDirective)")
        }
        if let mem = memorySection, !mem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemSections.append(mem)
        }
        
        let boundedHistory = await sessionManager.getBoundedHistory(sessionID: request.sessionID)
        let modelContext = ModelExecutionContext(
            systemPrompt: systemSections.joined(separator: "\n\n"),
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
            
            if modelRes.toolCalls.count >= 2 {
                // Multi-step model plan -> route through bounded PlanExecutor harness
                KillSwitch.shared.reset()
                let executor = effectivePlanExecutor()
                let planSteps: [PlanStep] = modelRes.toolCalls.enumerated().map { idx, call in
                    let registeredTool = lookupTool(named: call.toolName)
                    return PlanStep(
                        index: idx,
                        description: call.toolName,
                        toolName: call.toolName,
                        arguments: call.arguments,
                        status: .pending,
                        resultMessage: nil,
                        reversible: registeredTool?.isReversible ?? false
                    )
                }
                do {
                    let job = try await executor.executePlan(
                        goal: effectiveUtterance,
                        steps: planSteps,
                        context: toolContext,
                        archetype: activeArchetype
                    )
                    let duration = elapsedMs()
                    let stepLines = job.steps.map { step in
                        "• [\(step.status.rawValue)] \(step.toolName): \(step.resultMessage ?? "")"
                    }
                    let summaryMsg = stepLines.joined(separator: "\n")
                    let isConfirmation = job.status == .pausedForApproval
                    let finalMsg = isConfirmation
                        ? "Confirmation required for multi-step plan '\(job.goal)' (Job \(String(job.id.prefix(8))))."
                        : summaryMsg
                    let toolRecords = job.steps.map { step in
                        ToolExecutionRecord(
                            toolName: step.toolName,
                            arguments: step.arguments,
                            success: step.status == .completed,
                            resultMessage: step.resultMessage ?? "",
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
                        assistantResponse: finalMsg,
                        tokenUsage: modelRes.usage,
                        latencyMs: duration
                    )
                    await sessionManager.recordTurn(turn, sessionID: request.sessionID)
                    let pausedStep = isConfirmation ? job.steps.first(where: { $0.status == .pausedForApproval }) : nil
                    return finalizeResponse(
                        text: finalMsg,
                        request: request,
                        badge: modelRes.badge,
                        latencyMs: duration,
                        success: job.status == .completed,
                        isConfirmation: isConfirmation,
                        confirmationToolName: pausedStep?.toolName,
                        confirmationArguments: pausedStep?.arguments,
                        confirmationReason: isConfirmation ? pausedStep?.resultMessage : nil
                    )
                } catch {
                    // Fall through to standard single-turn executor on harness setup error
                }
            }
            
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
            
            let isConfirmation = summary.results.contains { res in
                !res.success && (
                    res.message.localizedCaseInsensitiveContains("confirmation required") ||
                    res.message.localizedCaseInsensitiveContains("user confirmation required")
                )
            } || finalMessage.localizedCaseInsensitiveContains("confirmation required")
            let succeeded = summary.toolCallsSucceeded > 0 && summary.toolCallsSucceeded == summary.results.count
            let confirmIdx = summary.results.firstIndex(where: {
                !$0.success && $0.message.localizedCaseInsensitiveContains("confirmation required")
            })
            let confirmCall = confirmIdx.flatMap { $0 < modelRes.toolCalls.count ? modelRes.toolCalls[$0] : nil }
            let confirmMsg = confirmIdx.map { summary.results[$0].message }
            return finalizeResponse(
                text: finalMessage,
                request: request,
                badge: modelRes.badge,
                latencyMs: duration,
                success: succeeded,
                isConfirmation: isConfirmation,
                toolResults: summary.results,
                confirmationToolName: confirmCall?.toolName,
                confirmationArguments: confirmCall?.arguments,
                confirmationReason: confirmMsg
            )
        }
        
        // Conversational response without tool calls
        let isOfflineFallback = (modelRes.providerName == "Offline Fallback")
        if !isOfflineFallback {
            await memoryProvider?.proposePreferenceIfApplicable(utterance: trimmed, trust: effectiveTrust)
        }
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
        
        let isConfirmation = !isOfflineFallback && (
            modelRes.content.localizedCaseInsensitiveContains("confirmation required") ||
            modelRes.content.localizedCaseInsensitiveContains("user confirmation required")
        )
        return finalizeResponse(
            text: modelRes.content,
            request: request,
            badge: modelRes.badge,
            latencyMs: duration,
            success: !isOfflineFallback,
            isConfirmation: isConfirmation
        )
    }
    
    private func lookupTool(named name: String) -> (any PearlTool)? {
        return toolRegistry.tool(named: name) ??
            (toolRegistry === ToolRegistry.shared ? CentralToolCatalog.shared.tool(named: name) : nil)
    }
    
    private func effectivePlanExecutor() -> PlanExecutor {
        if toolRegistry === ToolRegistry.shared && policyEngine === PolicyEngine.shared {
            return .shared
        }
        return PlanExecutor(policyEngine: policyEngine, toolRegistry: toolRegistry)
    }
    
    private enum DisambiguationOutcome {
        case resolved(ResolvedIntent)
        case earlyResponse(AssistantResponse)
    }
    
    private func disambiguateFilesystemIntent(
        _ intent: ResolvedIntent,
        request: AssistantRequest,
        elapsedMs: () -> Double
    ) async -> DisambiguationOutcome? {
        guard intent.toolName == "rename_file" else { return nil }
        guard let rawSource = intent.arguments["source"],
              !rawSource.contains("/"),
              !rawSource.hasPrefix("~") else {
            return nil
        }
        
        // 1. Check recent session turns for exact matching filename
        let recent = await sessionManager.getRecentTurns(sessionID: request.sessionID)
        if let recentPath = referenceResolver.extractMostRecentPathEntity(from: recent) {
            let expanded = (recentPath as NSString).expandingTildeInPath
            if (expanded as NSString).lastPathComponent.lowercased() == rawSource.lowercased() {
                let parent = (recentPath as NSString).deletingLastPathComponent
                let newName = intent.arguments["destination"] ?? ""
                let resolvedDest = (newName.contains("/") || newName.hasPrefix("~"))
                    ? newName
                    : (parent as NSString).appendingPathComponent(newName)
                var args = intent.arguments
                args["source"] = recentPath
                args["destination"] = resolvedDest
                return .resolved(ResolvedIntent(toolName: "rename_file", arguments: args, confidence: intent.confidence))
            }
        }
        
        // 2. Check approved folders on disk for unique vs ambiguous matches (never guess)
        let allowed = PearlConfig.load().allowedFolders
        let fm = FileManager.default
        var matches: [(approved: String, full: String)] = []
        for folder in allowed {
            let expandedDir = (folder as NSString).expandingTildeInPath
            let candidate = (expandedDir as NSString).appendingPathComponent(rawSource)
            if fm.fileExists(atPath: candidate) {
                matches.append((folder, (folder as NSString).appendingPathComponent(rawSource)))
            }
        }
        
        if matches.count == 1 {
            let match = matches[0]
            let parent = (match.full as NSString).deletingLastPathComponent
            let newName = intent.arguments["destination"] ?? ""
            let resolvedDest = (newName.contains("/") || newName.hasPrefix("~"))
                ? newName
                : (parent as NSString).appendingPathComponent(newName)
            var args = intent.arguments
            args["source"] = match.full
            args["destination"] = resolvedDest
            return .resolved(ResolvedIntent(toolName: "rename_file", arguments: args, confidence: intent.confidence))
        }
        
        if matches.isEmpty {
            let msg = "Could not find '\(rawSource)' in your approved folders (Desktop, Documents, Downloads, Projects). Specify its full path to proceed."
            return .earlyResponse(finalizeResponse(
                text: msg,
                request: request,
                badge: HUDTurnBadge(label: "not found", provider: "Deterministic", modelID: "rename_file", isLocal: true),
                latencyMs: elapsedMs(),
                success: false
            ))
        }
        
        let newName = intent.arguments["destination"] ?? ""
        let locationChoices = matches.map(\.approved).joined(separator: ", ")
        let prompt = "Multiple matches found for '\(rawSource)' (\(locationChoices)). Which folder did you mean?"
        await sessionManager.setPendingClarification(
            PendingClarification(
                kind: "rename_source",
                prompt: prompt,
                targets: [rawSource],
                newName: newName
            ),
            sessionID: request.sessionID
        )
        let response = finalizeResponse(
            text: prompt,
            request: request,
            badge: HUDTurnBadge(label: "clarify", provider: "Deterministic", modelID: "clarification", isLocal: true),
            latencyMs: elapsedMs(),
            success: true,
            needsClarification: true
        )
        return .earlyResponse(response)
    }
    
    private func executeMatchedSkill(
        _ skill: SkillDefinition,
        request: AssistantRequest,
        effectiveUtterance: String,
        effectiveTrust: TrustLevel,
        archetype: SpecialistArchetype? = nil,
        elapsedMs: () -> Double
    ) async -> AssistantResponse {
        KillSwitch.shared.reset()
        var planSteps: [PlanStep] = []
        for (idx, stepDef) in skill.steps.enumerated() {
            if let intent = router.resolve(utterance: stepDef.utterance) {
                let reversible = lookupTool(named: intent.toolName)?.isReversible ?? false
                planSteps.append(PlanStep(
                    index: idx,
                    description: stepDef.description,
                    toolName: intent.toolName,
                    arguments: intent.arguments,
                    status: .pending,
                    resultMessage: nil,
                    reversible: reversible
                ))
            }
        }
        
        guard !planSteps.isEmpty else {
            return finalizeResponse(
                text: "Skill '\(skill.name)' contains no deterministically resolvable tool steps.",
                request: request,
                badge: HUDTurnBadge(label: "skill", provider: "SkillEngine", modelID: skill.name, isLocal: true),
                latencyMs: elapsedMs(),
                success: false
            )
        }
        
        let toolContext = ToolExecutionContext(
            trustState: effectiveTrust,
            userConfirmed: request.userConfirmed,
            providerIsLocal: true,
            taintState: request.clientTaintState,
            freshConfirmationArgs: request.freshConfirmationArgs
        )
        
        do {
            let job = try await PlanExecutor.shared.executePlan(
                goal: "Skill: \(skill.name)",
                steps: planSteps,
                context: toolContext,
                archetype: archetype
            )
            let duration = elapsedMs()
            let lines = job.steps.map { step in
                "• [\(step.status.rawValue)] \(step.description): \(step.resultMessage ?? "")"
            }
            let summaryText = "Ran skill '\(skill.name)' (\(job.status.rawValue)):\n" + lines.joined(separator: "\n")
            let isConfirmation = job.status == .pausedForApproval
            let records = job.steps.map { step in
                ToolExecutionRecord(
                    toolName: step.toolName,
                    arguments: step.arguments,
                    success: step.status == .completed,
                    resultMessage: step.resultMessage ?? "",
                    durationMs: duration
                )
            }
            let turn = ConversationTurn(
                turnId: UUID(),
                timestamp: Date(),
                rawInput: request.utterance,
                cleanedInput: effectiveUtterance,
                resolvedIntent: nil,
                toolInvocations: records,
                assistantResponse: summaryText,
                tokenUsage: nil,
                latencyMs: duration
            )
            await sessionManager.recordTurn(turn, sessionID: request.sessionID)
            return finalizeResponse(
                text: summaryText,
                request: request,
                badge: HUDTurnBadge(label: "skill", provider: "SkillEngine", modelID: skill.name, isLocal: true),
                latencyMs: duration,
                success: job.status == .completed,
                isConfirmation: isConfirmation
            )
        } catch {
            return finalizeResponse(
                text: "Skill execution failed: \(error.localizedDescription)",
                request: request,
                badge: HUDTurnBadge(label: "error", provider: "SkillEngine", modelID: skill.name, isLocal: true),
                latencyMs: elapsedMs(),
                success: false
            )
        }
    }
    
    private func handleBuiltInIntent(
        _ intent: ResolvedIntent,
        request: AssistantRequest,
        effectiveUtterance: String,
        elapsedMs: () -> Double
    ) async -> AssistantResponse? {
        switch intent.toolName {
        case "clarify_destination":
            let kind = intent.arguments["kind"] ?? "create_directory"
            let rawNames = intent.arguments["names"] ?? ""
            let targets = rawNames.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            let prompt = intent.clarificationPrompt ?? intent.arguments["prompt"] ?? "Where should I create it: Desktop, Documents, Downloads or Projects?"
            await sessionManager.setPendingClarification(
                PendingClarification(
                    kind: kind,
                    prompt: prompt,
                    targets: targets
                ),
                sessionID: request.sessionID
            )
            return finalizeResponse(
                text: prompt,
                request: request,
                badge: HUDTurnBadge(label: "clarify", provider: "Deterministic", modelID: "clarification", isLocal: true),
                latencyMs: elapsedMs(),
                success: true,
                needsClarification: true
            )
        case "set_persona":
            let rawMode = (intent.arguments["mode"] ?? "executive").lowercased()
            let mode = PersonaMode(rawValue: rawMode) ?? .executive
            PersonaEngine.shared.setMode(mode)
            var cfg = PearlConfig.load()
            cfg.activePersona = mode.rawValue
            cfg.save()
            let msg = "Switched active persona to **\(mode.displayName)** — \(mode.description)"
            return finalizeResponse(
                text: msg,
                request: request,
                badge: HUDTurnBadge(label: mode.rawValue, provider: "PersonaEngine", modelID: mode.displayName, isLocal: true),
                latencyMs: elapsedMs()
            )
        case "dream_synthesis":
            let badge = HUDTurnBadge(label: "dream", provider: "DreamEngine", modelID: "synthesis", isLocal: true)
            guard let provider = memoryProvider else {
                return finalizeResponse(
                    text: "Dream synthesis unavailable: memory provider is not configured.",
                    request: request,
                    badge: badge,
                    latencyMs: elapsedMs(),
                    success: false
                )
            }
            do {
                let summary = try await provider.triggerDreamSynthesis()
                let duration = elapsedMs()
                let turn = ConversationTurn(
                    turnId: UUID(),
                    timestamp: Date(),
                    rawInput: request.utterance,
                    cleanedInput: effectiveUtterance,
                    resolvedIntent: intent,
                    toolInvocations: [],
                    assistantResponse: summary,
                    tokenUsage: nil,
                    latencyMs: duration
                )
                await sessionManager.recordTurn(turn, sessionID: request.sessionID)
                return finalizeResponse(text: summary, request: request, badge: badge, latencyMs: duration)
            } catch {
                return finalizeResponse(
                    text: "Dream synthesis skipped: \(error.localizedDescription)",
                    request: request,
                    badge: badge,
                    latencyMs: elapsedMs(),
                    success: false
                )
            }
        case "cache_stats":
            let report = CacheManager.shared.formattedSummary() + "\n\n" + PerformanceMonitor.shared.formattedSummary()
            return finalizeResponse(
                text: report,
                request: request,
                badge: HUDTurnBadge(label: "telemetry", provider: "CacheManager", modelID: "stats", isLocal: true),
                latencyMs: elapsedMs()
            )
        default:
            return nil
        }
    }
    
    private func handleMatchedRecipe(
        _ recipe: RecipeDefinition,
        request: AssistantRequest,
        effectiveUtterance: String,
        elapsedMs: () -> Double
    ) async -> AssistantResponse {
        let badge = HUDTurnBadge(label: "recipe", provider: "RecipeEngine", modelID: recipe.name, isLocal: true)
        if recipe.inputs.isEmpty {
            let rendered = (try? RecipeEngine.shared.renderRecipe(name: recipe.name, arguments: [:])) ?? recipe.body
            return finalizeResponse(
                text: "Recipe **\(recipe.name)** (\(recipe.description)):\n\n\(rendered)",
                request: request,
                badge: badge,
                latencyMs: elapsedMs()
            )
        }
        let usageArgs = recipe.inputs.map { "\($0)=<value>" }.joined(separator: " ")
        let msg = "Matched recipe **\(recipe.name)** — \(recipe.description).\nRequired inputs: \(recipe.inputs.joined(separator: ", ")).\nRun via: `pearl recipes run \(recipe.name) \(usageArgs)`"
        return finalizeResponse(text: msg, request: request, badge: badge, latencyMs: elapsedMs())
    }
    
    private func finalizeResponse(
        text: String,
        request: AssistantRequest,
        badge: HUDTurnBadge,
        latencyMs: Double,
        success: Bool = true,
        isConfirmation: Bool = false,
        memoryUpdated: Bool = false,
        toolResults: [ToolResult] = [],
        confirmationToolName: String? = nil,
        confirmationArguments: [String: String]? = nil,
        confirmationReason: String? = nil,
        needsClarification: Bool = false
    ) -> AssistantResponse {
        let decorated = PersonaEngine.shared.decorateResponse(
            text,
            isActionSuccess: success,
            isConfirmationOrJSON: isConfirmation || needsClarification
        )
        let decision = OutputDirector.shared.decide(
            responseText: decorated,
            origin: request.origin,
            isError: !success && !isConfirmation,
            requiresConfirmation: isConfirmation
        )
        return AssistantResponse(
            id: request.id,
            success: success,
            responseText: decorated,
            speechText: decision.spokenText ?? "",
            badge: badge,
            latencyMs: latencyMs,
            toolResults: toolResults,
            memoryUpdated: memoryUpdated,
            outputDecision: decision,
            requiresConfirmation: isConfirmation,
            confirmationToolName: confirmationToolName,
            confirmationArguments: confirmationArguments,
            confirmationReason: confirmationReason,
            needsClarification: needsClarification
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
