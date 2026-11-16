import Foundation
import XCTest
@testable import PearlCore

private final class StubConfirmTool: PearlTool {
    let name: String
    let description = "Stub confirmation-gated tool"
    let tier: ToolTier
    let requiredTCC: [TCCService] = []
    let isReversible: Bool

    init(name: String, tier: ToolTier, isReversible: Bool) {
        self.name = name
        self.tier = tier
        self.isReversible = isReversible
    }

    func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        return ToolResult(success: true, message: "Stub executed \(name)")
    }
}

private final class StubFailingTool: PearlTool {
    let name: String
    let description = "Stub failing tool for pipeline verification"
    let tier: ToolTier
    let requiredTCC: [TCCService] = []
    let isReversible = false

    init(name: String, tier: ToolTier = .t1Reversible) {
        self.name = name
        self.tier = tier
    }

    func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        return ToolResult(success: false, message: "Simulated execution failure in \(name).")
    }
}

private actor RollbackRecorder {
    private(set) var revertedSteps: [String] = []
    func record(_ step: String) {
        revertedSteps.append(step)
    }
}

private final class StubReversibleTool: PearlTool {
    let name: String
    let description = "Stub reversible tool for rollback verification"
    let tier = ToolTier.t1Reversible
    let requiredTCC: [TCCService] = []
    let isReversible = true
    let recorder: RollbackRecorder

    init(name: String, recorder: RollbackRecorder) {
        self.name = name
        self.recorder = recorder
    }

    func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let label = args["label"] ?? name
        let rec = recorder
        return ToolResult(
            success: true,
            message: "Executed \(label).",
            undoAction: {
                await rec.record(label)
            }
        )
    }
}

/// Phase 1, Phase 4 & Phase 6 Pipeline, Catalog Consistency, Policy & PlanExecutor Tests.
final class PipelineAndToolConsistencyTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        KillSwitch.shared.reset()
        TaintTracker.shared.reset()
        await UndoJournal.shared.clear()
        CentralToolCatalog.shared.registerDefaultCoreTools()
    }

    override func tearDown() async throws {
        await UndoJournal.shared.clear()
        TaintTracker.shared.reset()
        KillSwitch.shared.reset()
        try await super.tearDown()
    }

    // MARK: - Phase 4: Unified Catalog Consistency & MCP Exposure Bound

    func testCatalogMetadataSyncAndMCPTierBoundary() {
        let registry = ToolRegistry()
        let taskTools: [any PearlTool] = [
            ListTasksTool(),
            CreateTaskTool(),
            CompleteTaskTool(),
            DeleteTaskTool()
        ]
        for tool in taskTools {
            registry.register(tool)
        }

        let catalog = CentralToolCatalog()
        for tool in taskTools {
            catalog.register(tool)
        }

        let report = catalog.auditConsistency(against: registry)
        XCTAssertTrue(report.missingFromToolRegistry.isEmpty, "Missing from registry: \(report.missingFromToolRegistry)")
        XCTAssertTrue(report.missingFromCatalog.isEmpty, "Missing from catalog: \(report.missingFromCatalog)")
        XCTAssertTrue(report.tierMismatches.isEmpty, "Tier mismatches: \(report.tierMismatches)")
        XCTAssertTrue(report.descriptorMismatches.isEmpty, "Descriptor mismatches: \(report.descriptorMismatches)")
        XCTAssertTrue(report.mcpViolations.isEmpty, "MCP tier violations: \(report.mcpViolations)")
        XCTAssertEqual(report.catalogCount, 4)
        XCTAssertEqual(report.registryCount, 4)

        // MCP exposed tools and catalog metadata must strictly stay within T0-T2
        for tool in catalog.exposedTools(for: .mcp) {
            XCTAssertLessThanOrEqual(tool.tier, ToolTier.t2ReadPersonal, "MCP exposed tool \(tool.name) exceeds T2!")
        }
        for meta in catalog.allMetadata() where meta.mcpExposed {
            XCTAssertLessThanOrEqual(meta.tier, ToolTier.t2ReadPersonal, "MCP catalog metadata \(meta.name) exceeds T2!")
        }
    }

    // MARK: - Phase 1: Confirmation Gating & Taint Defense

    func testPolicyEngineRequiresConfirmationAndBlocksTaintedConfirmationBypass() async {
        let policy = PolicyEngine()
        let gatedTools = ["delete_task", "trash_file", "rename_file", "move_file"]

        for toolName in gatedTools {
            let meta = CentralToolCatalog.shared.metadata(for: toolName)
            XCTAssertNotNil(meta, "Missing catalog metadata for \(toolName)")
            XCTAssertTrue(meta?.requiresConfirmation == true, "\(toolName) must require confirmation")

            let stubTool = StubConfirmTool(
                name: toolName,
                tier: meta?.tier ?? .t3WorkspaceChanges,
                isReversible: meta?.isReversible ?? true
            )

            let ctxUnconfirmed = ToolExecutionContext(trustState: .trusted, userConfirmed: false)
            let d1 = policy.evaluate(tool: stubTool, args: [:], context: ctxUnconfirmed)
            if case .confirmationRequired = d1 { } else {
                XCTFail("Expected .confirmationRequired for unconfirmed \(toolName), got \(d1)")
            }

            let ctxConfirmedClean = ToolExecutionContext(
                trustState: .trusted,
                userConfirmed: true,
                taintState: .clean,
                freshConfirmationArgs: [:]
            )
            let d2 = policy.evaluate(tool: stubTool, args: [:], context: ctxConfirmedClean)
            if case .allowed = d2 { } else {
                XCTFail("Expected .allowed for clean confirmed \(toolName), got \(d2)")
            }

            // Tainted context with confirm=true arg must NEVER auto-allow or bypass confirmation
            let ctxTainted = ToolExecutionContext(
                trustState: .untrusted,
                userConfirmed: false,
                taintState: .tainted(source: "external_file", reason: "untrusted content")
            )
            let d3 = policy.evaluate(tool: stubTool, args: ["confirm": "true"], context: ctxTainted)
            if case .allowed = d3 {
                XCTFail("Tainted context must NEVER return .allowed for \(toolName)")
            }
            let execTainted = try? await policy.execute(tool: stubTool, args: ["confirm": "true"], context: ctxTainted)
            XCTAssertFalse(execTainted?.success ?? true, "Tainted tool execution with injected confirm=true must be blocked")
        }
    }

    // MARK: - Phase 6: PlanExecutor Real Failure Propagation & Rollback

    func testPlanExecutorDoesNotFabricateSuccessWhenApprovedStepFails() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pearl_plan_fail_\(UUID().uuidString).sqlite")
        let approvalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pearl_approvals_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: approvalURL)
        }

        let jobStore = try JobStore(databaseURL: storeURL)
        let registry = ToolRegistry()
        let queue = ApprovalQueue(storageURL: approvalURL, toolRegistry: registry)
        let recorder = RollbackRecorder()

        registry.register(StubReversibleTool(name: "stub_ok", recorder: recorder))
        registry.register(StubFailingTool(name: "close_app", tier: .t4ExternalSideEffects))

        let undoJournal = UndoJournal()
        let executor = PlanExecutor(
            maxSteps: 8,
            memoryCeilingMB: 256.0,
            jobStore: jobStore,
            approvalQueue: queue,
            killSwitch: KillSwitch(),
            policyEngine: PolicyEngine(undoJournal: undoJournal),
            toolRegistry: registry,
            undoJournal: undoJournal,
            memoryReader: { 10.0 }
        )

        let steps = [
            PlanStep(index: 0, description: "Step 1 ok", toolName: "stub_ok", arguments: ["label": "step1"], reversible: true),
            PlanStep(index: 1, description: "Step 2 needs approval and fails", toolName: "close_app", arguments: ["app": "Fake"]),
            PlanStep(index: 2, description: "Step 3 dependent", toolName: "stub_ok", arguments: ["label": "step3"], reversible: true)
        ]

        let pausedJob = try await executor.executePlan(
            goal: "Test real approval outcome propagation",
            steps: steps,
            context: ToolExecutionContext(),
            userPresent: true
        )
        XCTAssertEqual(pausedJob.status, PlanJobStatus.pausedForApproval, "Unexpected status: \(pausedJob.status) error=\(pausedJob.errorMessage ?? "nil")")
        XCTAssertEqual(pausedJob.steps[0].status, PlanStepStatus.completed)

        let pending = await queue.listPending().filter { $0.jobId == pausedJob.id }
        guard let firstApproval = pending.first else {
            return XCTFail("Expected 1 pending approval for job \(pausedJob.id), status=\(pausedJob.status), err=\(pausedJob.errorMessage ?? "nil")")
        }
        XCTAssertEqual(pending.count, 1)

        // Approving executes the failing tool handler -> executionSucceeded MUST be false
        let approvalResult = try await queue.approve(id: firstApproval.id)
        XCTAssertFalse(approvalResult.success)

        // Resuming the job MUST mark the step & job as .failed and NOT advance to step 3!
        let resumed = try await executor.resumeJob(id: pausedJob.id, context: ToolExecutionContext())
        XCTAssertEqual(resumed.status, PlanJobStatus.failed)
        XCTAssertEqual(resumed.steps[1].status, PlanStepStatus.failed)
        XCTAssertEqual(resumed.steps[2].status, PlanStepStatus.pending)

        // Rollback reverts step 1 cleanly
        let rolledCount = try await executor.rollbackJob(id: pausedJob.id)
        XCTAssertEqual(rolledCount, 1)
        let reverted = await recorder.revertedSteps
        XCTAssertEqual(reverted, ["step1"])
    }

    // MARK: - Phase 1: Offline Fallback Action Failure Semantics

    func testAssistantPipelineReportsFailureWhenOfflineOnUnresolvedActionCommand() async {
        let registry = ToolRegistry()
        let pipeline = AssistantPipeline(
            router: DeterministicRouter(),
            toolRegistry: registry,
            policyEngine: PolicyEngine(),
            toolExecutor: ModelToolExecutor(registry: registry),
            fallbackChain: FallbackChain(pccEnabled: false),
            sessionManager: SessionManager(),
            referenceResolver: ContextReferenceResolver()
        )

        let req = AssistantRequest(
            utterance: "Do something completely custom inside my workspace that has no deterministic rule",
            origin: .cli,
            forceEscalation: true
        )
        let resp = await pipeline.process(request: req)
        XCTAssertFalse(resp.success, "Offline fallback must never report fabricated action success")
    }

    // MARK: - Phase 3: Pronoun / Anaphora Reference Resolution

    func testContextReferenceResolverResolvesPronounsAcrossTurns() {
        let resolver = ContextReferenceResolver()
        let history = [
            ConversationTurn(
                rawInput: "Create a folder called Research",
                cleanedInput: "create a folder called Research",
                resolvedIntent: ResolvedIntent(
                    toolName: "create_directory",
                    arguments: ["path": "~/Desktop/Research"],
                    confidence: 1.0
                ),
                toolInvocations: [
                    ToolExecutionRecord(
                        toolName: "create_directory",
                        arguments: ["path": "~/Desktop/Research"],
                        success: true,
                        resultMessage: "Created directory at '~/Desktop/Research'."
                    )
                ],
                assistantResponse: "Created directory at '~/Desktop/Research'."
            )
        ]

        let result = resolver.resolve(utterance: "rename it to Archive", history: history)
        XCTAssertTrue(
            result.didResolve && result.resolvedUtterance.lowercased().contains("research"),
            "Expected pronoun resolution to resolve 'it' to Research path, got: \(result.resolvedUtterance)"
        )
    }
}
