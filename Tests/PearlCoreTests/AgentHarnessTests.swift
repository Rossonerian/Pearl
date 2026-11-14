import XCTest
@testable import PearlCore

private struct MockHarnessTool: PearlTool {
    let name: String
    let description: String
    let tier: ToolTier
    let requiredTCC: [TCCService] = []
    let isReversible: Bool
    var executeHandler: (@Sendable ([String: String], ToolExecutionContext) async throws -> ToolResult)?
    
    init(
        name: String,
        description: String = "Mock harness tool",
        tier: ToolTier = .t0Observe,
        isReversible: Bool = false,
        executeHandler: (@Sendable ([String: String], ToolExecutionContext) async throws -> ToolResult)? = nil
    ) {
        self.name = name
        self.description = description
        self.tier = tier
        self.isReversible = isReversible
        self.executeHandler = executeHandler
    }
    
    func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        if let handler = executeHandler {
            return try await handler(args, context)
        }
        return ToolResult(
            success: true,
            message: "Executed \(name)",
            trust: context.trustState
        )
    }
}

final class AgentHarnessTests: XCTestCase {
    var tempDir: URL!
    var jobStoreURL: URL!
    var approvalsURL: URL!
    var jobStore: JobStore!
    var approvalQueue: ApprovalQueue!
    var killSwitch: KillSwitch!
    var policyEngine: PolicyEngine!
    var toolRegistry: ToolRegistry!
    var executor: PlanExecutor!
    
    override func setUp() async throws {
        try await super.setUp()
        
        let unique = UUID().uuidString
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PearlHarnessTests_\(unique)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        
        jobStoreURL = tempDir.appendingPathComponent("jobs_\(unique).sqlite")
        approvalsURL = tempDir.appendingPathComponent("approvals_\(unique).json")
        
        jobStore = try JobStore(databaseURL: jobStoreURL)
        killSwitch = KillSwitch()
        policyEngine = PolicyEngine()
        toolRegistry = ToolRegistry()
        approvalQueue = ApprovalQueue(storageURL: approvalsURL, policyEngine: policyEngine, toolRegistry: toolRegistry)
        
        await UndoJournal.shared.clear()
        TaintTracker.shared.reset()
        
        executor = PlanExecutor(
            maxSteps: 8,
            memoryCeilingMB: 45.0,
            jobStore: jobStore,
            approvalQueue: approvalQueue,
            killSwitch: killSwitch,
            policyEngine: policyEngine,
            toolRegistry: toolRegistry,
            undoJournal: .shared,
            memoryReader: { 20.0 } // Normal safe memory level
        )
    }
    
    override func tearDown() async throws {
        await UndoJournal.shared.clear()
        TaintTracker.shared.reset()
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }
    
    // MARK: - 1. Successful 3-Step Plan Execution & SQLite Persistence
    
    func testSuccessfulThreeStepPlanExecutionAndPersistence() async throws {
        toolRegistry.register(MockHarnessTool(name: "step_one", tier: .t0Observe))
        toolRegistry.register(MockHarnessTool(name: "step_two", tier: .t1Reversible))
        toolRegistry.register(MockHarnessTool(name: "step_three", tier: .t0Observe))
        
        let steps = [
            PlanStep(index: 0, description: "First observe", toolName: "step_one"),
            PlanStep(index: 1, description: "Second reversible", toolName: "step_two"),
            PlanStep(index: 2, description: "Third finalize", toolName: "step_three")
        ]
        
        let job = try await executor.executePlan(goal: "Execute 3-step test plan", steps: steps)
        
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.currentStepIndex, 3)
        XCTAssertEqual(job.steps.count, 3)
        XCTAssertTrue(job.steps.allSatisfy { $0.status == .completed })
        XCTAssertNil(job.errorMessage)
        
        // Verify SQLite persistence
        let loadedJob = try await jobStore.getJob(id: job.id)
        XCTAssertNotNil(loadedJob)
        XCTAssertEqual(loadedJob?.id, job.id)
        XCTAssertEqual(loadedJob?.status, .completed)
        XCTAssertEqual(loadedJob?.currentStepIndex, 3)
        XCTAssertEqual(loadedJob?.steps.count, 3)
        XCTAssertEqual(loadedJob?.steps[0].resultMessage, "Executed step_one")
        XCTAssertEqual(loadedJob?.steps[1].resultMessage, "Executed step_two")
        XCTAssertEqual(loadedJob?.steps[2].resultMessage, "Executed step_three")
        
        let allJobs = try await jobStore.listJobs(status: .completed)
        XCTAssertEqual(allJobs.count, 1)
        XCTAssertEqual(allJobs.first?.id, job.id)
    }
    
    // MARK: - 2. Step Cap (8 Steps) Truncation & strictStepCap Error
    
    func testStepCapTruncationWhenNonStrict() async throws {
        for i in 0..<12 {
            toolRegistry.register(MockHarnessTool(name: "tool_\(i)", tier: .t0Observe))
        }
        
        let steps = (0..<12).map { i in
            PlanStep(index: i, description: "Step \(i)", toolName: "tool_\(i)")
        }
        
        // strictStepCap: false -> should slice to 8 steps
        let job = try await executor.executePlan(goal: "Truncation test", steps: steps, strictStepCap: false)
        
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.steps.count, 8)
        XCTAssertEqual(job.currentStepIndex, 8)
        XCTAssertEqual(job.steps.last?.toolName, "tool_7")
    }
    
    func testStepCapThrowsWhenStrict() async throws {
        let steps = (0..<10).map { i in
            PlanStep(index: i, description: "Step \(i)", toolName: "tool_\(i)")
        }
        
        do {
            _ = try await executor.executePlan(goal: "Strict cap test", steps: steps, strictStepCap: true)
            XCTFail("Expected stepCapExceeded error to be thrown")
        } catch let PlanExecutorError.stepCapExceeded(maxSteps, requested) {
            XCTAssertEqual(maxSteps, 8)
            XCTAssertEqual(requested, 10)
        } catch {
            XCTFail("Unexpected error thrown: \(error)")
        }
    }
    
    // MARK: - 3. Kill Switch Mid-Execution Aborts Cleanly
    
    func testKillSwitchTriggerMidExecutionAbortsAtCheckpoint() async throws {
        let step0Called = Box(false)
        let step1Called = Box(false)
        let step2Called = Box(false)
        
        toolRegistry.register(MockHarnessTool(name: "ks_step0", tier: .t0Observe) { _, _ in
            step0Called.value = true
            return ToolResult(success: true, message: "Step 0 ok")
        })
        
        toolRegistry.register(MockHarnessTool(name: "ks_step1", tier: .t0Observe) { _, _ in
            step1Called.value = true
            return ToolResult(success: true, message: "Step 1 ok")
        })
        
        toolRegistry.register(MockHarnessTool(name: "ks_step2", tier: .t0Observe) { _, _ in
            step2Called.value = true
            return ToolResult(success: true, message: "Step 2 ok")
        })
        
        let steps = [
            PlanStep(index: 0, description: "Safe step 0", toolName: "ks_step0"),
            PlanStep(index: 1, description: "Triggered step 1", toolName: "ks_step1"),
            PlanStep(index: 2, description: "Should never run step 2", toolName: "ks_step2")
        ]
        
        // Trigger kill switch right after step 0 progress callback
        let handlerTriggered = Box(false)
        killSwitch.onTrigger { reason in
            handlerTriggered.value = true
            XCTAssertEqual(reason, "Emergency user halt")
        }
        
        let job = try await executor.executePlan(
            goal: "Kill switch plan",
            steps: steps,
            onStepProgress: { idx, _, _ in
                if idx == 1 {
                    self.killSwitch.trigger(reason: "Emergency user halt")
                }
            }
        )
        
        XCTAssertEqual(job.status, .aborted)
        XCTAssertEqual(job.errorMessage, "Emergency user halt")
        XCTAssertEqual(job.currentStepIndex, 1)
        XCTAssertEqual(job.steps[0].status, .completed)
        XCTAssertEqual(job.steps[1].status, .pending)
        XCTAssertEqual(job.steps[2].status, .pending)
        
        XCTAssertTrue(step0Called.value)
        XCTAssertFalse(step1Called.value)
        XCTAssertFalse(step2Called.value)
        XCTAssertTrue(handlerTriggered.value)
        XCTAssertEqual(killSwitch.triggerCount, 1)
        XCTAssertTrue(killSwitch.isAborted)
        
        // Verify SQLite persisted aborted state
        let persisted = try await jobStore.getJob(id: job.id)
        XCTAssertEqual(persisted?.status, .aborted)
        XCTAssertEqual(persisted?.errorMessage, "Emergency user halt")
        
        // Reset kill switch
        killSwitch.reset()
        XCTAssertFalse(killSwitch.isAborted)
        XCTAssertNil(killSwitch.lastReason)
    }
    
    // MARK: - 4. Memory Ceiling Guard
    
    func testMemoryCeilingGuardPausesJob() async throws {
        toolRegistry.register(MockHarnessTool(name: "mem_tool", tier: .t0Observe))
        
        let memExecutor = PlanExecutor(
            maxSteps: 8,
            memoryCeilingMB: 45.0,
            jobStore: jobStore,
            approvalQueue: approvalQueue,
            killSwitch: killSwitch,
            policyEngine: policyEngine,
            toolRegistry: toolRegistry,
            undoJournal: .shared,
            memoryReader: { 60.0 } // 60 MB exceeds 45 MB ceiling
        )
        
        let steps = [
            PlanStep(index: 0, description: "Memory check step", toolName: "mem_tool")
        ]
        
        let job = try await memExecutor.executePlan(goal: "Memory ceiling test", steps: steps)
        
        XCTAssertEqual(job.status, .pausedForMemory)
        XCTAssertEqual(job.currentStepIndex, 0)
        XCTAssertTrue(job.errorMessage?.contains("Memory ceiling exceeded") == true)
        
        let persisted = try await jobStore.getJob(id: job.id)
        XCTAssertEqual(persisted?.status, .pausedForMemory)
    }
    
    // MARK: - 5. ApprovalQueue Pauses on T4 / Confirmation-Required & Approve Executes
    
    func testApprovalQueuePausesOnT4AndExecutesOnApprove() async throws {
        let t4Executed = Box(false)
        toolRegistry.register(MockHarnessTool(name: "obs_tool", tier: .t0Observe))
        toolRegistry.register(MockHarnessTool(name: "deploy_prod", tier: .t4ExternalSideEffects) { _, _ in
            t4Executed.value = true
            return ToolResult(success: true, message: "Production deployed successfully")
        })
        
        let steps = [
            PlanStep(index: 0, description: "Pre-flight check", toolName: "obs_tool"),
            PlanStep(index: 1, description: "Deploy to production", toolName: "deploy_prod", arguments: ["env": "prod"])
        ]
        
        // User confirmed is false -> T4 requires confirmation
        let job = try await executor.executePlan(
            goal: "Deploy plan",
            steps: steps,
            context: ToolExecutionContext(trustState: .trusted, userConfirmed: false)
        )
        
        XCTAssertEqual(job.status, .pausedForApproval)
        XCTAssertEqual(job.currentStepIndex, 1)
        XCTAssertEqual(job.steps[0].status, .completed)
        XCTAssertEqual(job.steps[1].status, .pausedForApproval)
        XCTAssertFalse(t4Executed.value)
        
        // Verify ApprovalQueue has the pending item
        let pending = await approvalQueue.listPending()
        XCTAssertEqual(pending.count, 1)
        guard let approvalItem = pending.first else {
            return XCTFail("Expected pending approval item")
        }
        XCTAssertEqual(approvalItem.toolName, "deploy_prod")
        XCTAssertEqual(approvalItem.tier, .t4ExternalSideEffects)
        XCTAssertEqual(approvalItem.jobId, job.id)
        XCTAssertEqual(approvalItem.arguments["env"], "prod")
        XCTAssertEqual(approvalItem.status, .pending)
        
        // Approve through ApprovalQueue
        let toolResult = try await approvalQueue.approve(id: approvalItem.id)
        XCTAssertTrue(toolResult.success)
        XCTAssertEqual(toolResult.message, "Production deployed successfully")
        XCTAssertTrue(t4Executed.value)
        
        let resolvedItem = await approvalQueue.getApproval(id: approvalItem.id)
        XCTAssertEqual(resolvedItem?.status, .approved)
        let pendingAfter = await approvalQueue.listPending()
        XCTAssertEqual(pendingAfter.count, 0)
        
        // Double approval should throw alreadyResolved
        do {
            _ = try await approvalQueue.approve(id: approvalItem.id)
            XCTFail("Expected alreadyResolved error")
        } catch let ApprovalQueueError.alreadyResolved(id) {
            XCTAssertEqual(id, approvalItem.id)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testApprovalQueueAwayModePausesT2Action() async throws {
        toolRegistry.register(MockHarnessTool(name: "read_contacts", tier: .t2ReadPersonal))
        
        let steps = [
            PlanStep(index: 0, description: "Read user contacts", toolName: "read_contacts")
        ]
        
        // User not present -> userPresent: false restricts T2+
        let job = try await executor.executePlan(
            goal: "Away mode test",
            steps: steps,
            context: ToolExecutionContext(trustState: .trusted, userConfirmed: false),
            userPresent: false
        )
        
        XCTAssertEqual(job.status, .pausedForApproval)
        XCTAssertEqual(job.steps[0].status, .pausedForApproval)
        
        let pending = await approvalQueue.listPending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.toolName, "read_contacts")
        XCTAssertTrue(pending.first?.reason.contains("Away mode active") == true)
    }
    
    // MARK: - 6. ResumeJob Resumes from Exact Checkpointed Index
    
    func testResumeJobFromCheckpoint() async throws {
        let step1Ran = Box(false)
        let step2Ran = Box(false)
        
        toolRegistry.register(MockHarnessTool(name: "res_step0", tier: .t0Observe))
        toolRegistry.register(MockHarnessTool(name: "res_step1", tier: .t4ExternalSideEffects) { _, _ in
            step1Ran.value = true
            return ToolResult(success: true, message: "T4 step executed")
        })
        toolRegistry.register(MockHarnessTool(name: "res_step2", tier: .t0Observe) { _, _ in
            step2Ran.value = true
            return ToolResult(success: true, message: "Final step executed")
        })
        
        let steps = [
            PlanStep(index: 0, description: "Step 0", toolName: "res_step0"),
            PlanStep(index: 1, description: "Step 1 T4", toolName: "res_step1"),
            PlanStep(index: 2, description: "Step 2 final", toolName: "res_step2")
        ]
        
        let pausedJob = try await executor.executePlan(goal: "Resume test", steps: steps)
        XCTAssertEqual(pausedJob.status, .pausedForApproval)
        XCTAssertEqual(pausedJob.currentStepIndex, 1)
        XCTAssertFalse(step1Ran.value)
        XCTAssertFalse(step2Ran.value)
        
        // Approve via ApprovalQueue
        let pending = await approvalQueue.listPending()
        XCTAssertEqual(pending.count, 1)
        let approvalId = try XCTUnwrap(pending.first?.id)
        _ = try await approvalQueue.approve(id: approvalId)
        XCTAssertTrue(step1Ran.value)
        
        // Resume job: should detect step 1 was approved, advance to step 2, execute step 2, and complete
        let resumedJob = try await executor.resumeJob(id: pausedJob.id)
        XCTAssertEqual(resumedJob.status, .completed)
        XCTAssertEqual(resumedJob.currentStepIndex, 3)
        XCTAssertTrue(step2Ran.value)
        XCTAssertEqual(resumedJob.steps[0].status, .completed)
        XCTAssertEqual(resumedJob.steps[1].status, .completed)
        XCTAssertEqual(resumedJob.steps[2].status, .completed)
        
        let persisted = try await jobStore.getJob(id: pausedJob.id)
        XCTAssertEqual(persisted?.status, .completed)
    }
    
    // MARK: - 7. RollbackJob Reverses Completed Steps via UndoJournal
    
    func testRollbackJobReversesStepsViaUndoJournal() async throws {
        let revertLog = Box<[String]>([])
        
        toolRegistry.register(MockHarnessTool(name: "undo_step0", tier: .t1Reversible, isReversible: true) { _, context in
            return ToolResult(
                success: true,
                message: "Step 0 applied",
                undoAction: {
                    revertLog.value.append("undo_step0_reverted")
                }
            )
        })
        
        toolRegistry.register(MockHarnessTool(name: "undo_step1", tier: .t1Reversible, isReversible: true) { _, context in
            return ToolResult(
                success: true,
                message: "Step 1 applied",
                undoAction: {
                    revertLog.value.append("undo_step1_reverted")
                }
            )
        })
        
        toolRegistry.register(MockHarnessTool(name: "undo_step2_unreversible", tier: .t0Observe, isReversible: false) { _, context in
            return ToolResult(success: true, message: "Observation only")
        })
        
        let steps = [
            PlanStep(index: 0, description: "Reversible action 0", toolName: "undo_step0", reversible: true),
            PlanStep(index: 1, description: "Reversible action 1", toolName: "undo_step1", reversible: true),
            PlanStep(index: 2, description: "Non-reversible 2", toolName: "undo_step2_unreversible", reversible: false)
        ]
        
        let job = try await executor.executePlan(goal: "Rollback test", steps: steps)
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(revertLog.value.count, 0)
        
        // Rollback job: should undo the 2 reversible actions
        let revertedCount = try await executor.rollbackJob(id: job.id)
        XCTAssertEqual(revertedCount, 2)
        XCTAssertEqual(revertLog.value.count, 2)
        // UndoJournal is LIFO: step 1 undone first, then step 0
        XCTAssertEqual(revertLog.value, ["undo_step1_reverted", "undo_step0_reverted"])
        
        // Check job state in SQLite
        let rolledBackJob = try await jobStore.getJob(id: job.id)
        XCTAssertEqual(rolledBackJob?.status, .rolledBack)
        XCTAssertEqual(rolledBackJob?.steps[0].status, .rolledBack)
        XCTAssertEqual(rolledBackJob?.steps[1].status, .rolledBack)
        XCTAssertEqual(rolledBackJob?.steps[2].status, .rolledBack)
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
