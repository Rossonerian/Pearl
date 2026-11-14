import Foundation
import PearlCore
import PearlTools

@main
struct ConversationVerificationMain {
    static func main() async {
        print("=== Pearl V3: Conversation & Intelligence Engine Verification ===")
        var passed = 0
        var failed = 0
        
        func assertTest(_ condition: Bool, _ name: String) {
            if condition {
                print("  [PASS] \(name)")
                passed += 1
            } else {
                print("  [FAIL] \(name)")
                failed += 1
            }
        }
        
        // -------------------------------------------------------------
        // 1. ConversationTurn Tests
        // -------------------------------------------------------------
        print("\n1. Testing ConversationTurn Model...")
        let turnId = UUID()
        let now = Date()
        let record = ToolExecutionRecord(
            toolName: "open_app",
            arguments: ["app": "Safari"],
            success: true,
            resultMessage: "Opened Safari.",
            durationMs: 4.2
        )
        let turn = ConversationTurn(
            turnId: turnId,
            timestamp: now,
            rawInput: "open Safari",
            cleanedInput: "open Safari",
            resolvedIntent: ResolvedIntent(toolName: "open_app", arguments: ["app": "Safari"], confidence: 0.98),
            toolInvocations: [record],
            assistantResponse: "Opened Safari.",
            tokenUsage: TokenUsage(promptTokens: 10, completionTokens: 5),
            latencyMs: 12.5
        )
        assertTest(turn.turnId == turnId, "ConversationTurn stores UUID accurately")
        assertTest(turn.toolInvocations.count == 1, "ToolExecutionRecord preserved")
        assertTest(turn.estimatedTokens == 15, "TokenUsage priority respected for estimatedTokens")
        
        // Verify Codable roundtrip
        if let encoded = try? JSONEncoder().encode(turn),
           let decoded = try? JSONDecoder().decode(ConversationTurn.self, from: encoded) {
            assertTest(decoded.turnId == turnId && decoded.assistantResponse == "Opened Safari.", "ConversationTurn Codable roundtrip succeeds")
        } else {
            assertTest(false, "ConversationTurn Codable roundtrip succeeds")
        }
        
        // -------------------------------------------------------------
        // 2. SessionManager Sliding Window & Budget Tests
        // -------------------------------------------------------------
        print("\n2. Testing SessionManager...")
        let sessionManager = SessionManager(config: SessionManager.Configuration(defaultMaxTurns: 3, defaultTokenBudget: 100))
        await sessionManager.resetAll()
        
        // Record 5 turns with small tokens
        for i in 1...5 {
            let t = ConversationTurn(
                rawInput: "Turn \(i)",
                cleanedInput: "Turn \(i)",
                assistantResponse: "Response \(i)",
                tokenUsage: TokenUsage(promptTokens: 10, completionTokens: 10) // 20 tokens each
            )
            await sessionManager.recordTurn(t, sessionID: "test-session")
        }
        
        let metrics = await sessionManager.getMetrics(sessionID: "test-session")
        assertTest(metrics.totalTurns == 5, "SessionManager tracks total turns accurately (5)")
        
        let boundedByTurns = await sessionManager.getBoundedHistory(sessionID: "test-session", maxTurns: 3, tokenBudget: 1000)
        assertTest(boundedByTurns.count == 3, "Sliding window limits to last 3 turns")
        assertTest(boundedByTurns.first?.rawInput == "Turn 3" && boundedByTurns.last?.rawInput == "Turn 5", "Sliding window preserves chronological order")
        
        // Test hard token budget constraint: budget = 45 tokens (each turn is 20 tokens) -> should fit only 2 turns (Turn 4 and Turn 5)
        let boundedByTokens = await sessionManager.getBoundedHistory(sessionID: "test-session", maxTurns: 10, tokenBudget: 45)
        assertTest(boundedByTokens.count == 2, "Token budget limits history to 2 turns (40 tokens <= 45)")
        assertTest(boundedByTokens.first?.rawInput == "Turn 4" && boundedByTokens.last?.rawInput == "Turn 5", "Budget preserves freshest turns in chronological order")
        
        // Multi-session isolation
        let defaultTurns = await sessionManager.getRecentTurns(sessionID: "default")
        assertTest(defaultTurns.isEmpty, "Different session IDs are completely isolated")
        
        // -------------------------------------------------------------
        // 3. ContextReferenceResolver Tests
        // -------------------------------------------------------------
        print("\n3. Testing ContextReferenceResolver...")
        let resolver = ContextReferenceResolver()
        
        // Anaphora detection
        assertTest(resolver.containsAnaphora("now close it"), "Detects 'it' as anaphora")
        assertTest(resolver.containsAnaphora("what branch is that?"), "Detects 'that' as anaphora")
        assertTest(resolver.containsAnaphora("do it again"), "Detects 'again' as anaphora")
        assertTest(!resolver.containsAnaphora("git status"), "Does not falsely flag 'git' as 'it'")
        assertTest(!resolver.containsAnaphora("open Safari"), "Does not falsely flag fresh request")
        
        // Scenario A: "open Safari" -> "now close it"
        let turn1 = ConversationTurn(
            rawInput: "open Safari",
            cleanedInput: "open Safari",
            resolvedIntent: ResolvedIntent(toolName: "open_app", arguments: ["app": "Safari"], confidence: 0.98),
            toolInvocations: [ToolExecutionRecord(toolName: "open_app", arguments: ["app": "Safari"], success: true, resultMessage: "Opened Safari.")],
            assistantResponse: "Opened Safari."
        )
        let resA = resolver.resolve(utterance: "now close it", history: [turn1])
        assertTest(resA.didResolve, "Scenario A resolves successfully")
        assertTest(resA.antecedentEntity == "Safari", "Antecedent entity extracted as Safari")
        assertTest(resA.resolvedIntent?.toolName == "close_app", "Resolved intent routes to close_app")
        assertTest(resA.resolvedIntent?.arguments["app"] == "Safari", "Target app set to Safari")
        
        // Scenario B: "check git status in Pearl" -> "what branch is that?"
        let turnGit = ConversationTurn(
            rawInput: "check git status in Pearl",
            cleanedInput: "check git status in Pearl",
            resolvedIntent: ResolvedIntent(toolName: "git", arguments: ["subcommand": "status", "repo": "Pearl"], confidence: 0.98),
            toolInvocations: [ToolExecutionRecord(toolName: "git", arguments: ["subcommand": "status", "repo": "Pearl"], success: true, resultMessage: "Git clean.")],
            assistantResponse: "Git working tree is clean on branch main."
        )
        let resB = resolver.resolve(utterance: "what branch is that?", history: [turnGit])
        assertTest(resB.didResolve, "Scenario B resolves successfully")
        assertTest(resB.antecedentEntity == "Pearl", "Antecedent repo extracted as Pearl")
        assertTest(resB.resolvedIntent?.toolName == "git", "Resolved intent routes to git")
        assertTest(resB.resolvedIntent?.arguments["repo"] == "Pearl", "Target repo argument set to Pearl")
        
        // Scenario C: Replay "again"
        let resC = resolver.resolve(utterance: "again", history: [turnGit])
        assertTest(resC.didResolve && resC.resolvedIntent?.toolName == "git", "Replay 'again' repeats previous intent")
        
        // -------------------------------------------------------------
        // 4. StreamingResponseChunker Tests
        // -------------------------------------------------------------
        print("\n4. Testing StreamingResponseChunker...")
        let sampleText = "Hello, world! Pearl is active and ready."
        let tokens = StreamingResponseChunker.tokenize(text: sampleText)
        assertTest(!tokens.isEmpty, "Tokenizes text into non-empty chunk array")
        assertTest(tokens.joined() == sampleText, "Tokenization preserves full original text exactly")
        
        // Stream test with instant cadence
        var streamedChunks: [String] = []
        for await chunk in StreamingResponseChunker.stream(text: sampleText, cadence: .instant) {
            streamedChunks.append(chunk)
        }
        assertTest(streamedChunks == tokens, "AsyncStream yields identical sequence with instant cadence")
        
        // -------------------------------------------------------------
        // 5. AssistantPipeline Multi-Turn Integration Tests
        // -------------------------------------------------------------
        print("\n5. Testing AssistantPipeline Multi-Turn End-to-End...")
        let pipelineSession = "integration-session-\(UUID().uuidString)"
        
        // Register mock AppTool in ToolRegistry if needed
        let registry = ToolRegistry.shared
        registry.register(AppTool())
        registry.register(CloseAppTool())
        
        // Turn 1: "open Safari"
        let req1 = AssistantRequest(
            utterance: "open Safari",
            origin: .cli,
            sessionID: pipelineSession
        )
        let resp1 = await AssistantPipeline.shared.process(request: req1)
        assertTest(resp1.success, "Pipeline Turn 1 'open Safari' succeeds")
        
        // Verify Turn 1 was recorded in sessionManager
        let historyAfter1 = await AssistantPipeline.shared.sessionManager.getRecentTurns(sessionID: pipelineSession)
        assertTest(historyAfter1.count == 1, "Session history contains 1 recorded turn after Turn 1")
        assertTest(historyAfter1.first?.cleanedInput == "open Safari", "Recorded turn input is 'open Safari'")
        
        // Turn 2: "now close it"
        let req2 = AssistantRequest(
            utterance: "now close it",
            origin: .cli,
            sessionID: pipelineSession
        )
        let resp2 = await AssistantPipeline.shared.process(request: req2)
        assertTest(resp2.success, "Pipeline Turn 2 'now close it' resolves and succeeds")
        
        // Verify Turn 2 was recorded and anaphora was resolved
        let historyAfter2 = await AssistantPipeline.shared.sessionManager.getRecentTurns(sessionID: pipelineSession)
        assertTest(historyAfter2.count == 2, "Session history contains 2 recorded turns")
        assertTest(historyAfter2.last?.resolvedIntent?.toolName == "close_app", "Turn 2 resolved to close_app")
        assertTest(historyAfter2.last?.resolvedIntent?.arguments["app"] == "Safari", "Turn 2 target app resolved to Safari")
        
        print("\n=======================================================")
        print("VERIFICATION RESULTS: \(passed) passed, \(failed) failed")
        print("=======================================================")
        if failed > 0 {
            exit(1)
        }
    }
}
