import Foundation
import Darwin

public enum PlanExecutorError: Error, LocalizedError, Sendable {
    case jobNotFound(String)
    case stepCapExceeded(maxSteps: Int, requested: Int)
    case aborted(String)
    case memoryBudgetExceeded(currentMB: Double, limitMB: Double)
    
    public var errorDescription: String? {
        switch self {
        case .jobNotFound(let id):
            return "Job not found with ID: \(id)"
        case .stepCapExceeded(let maxSteps, let requested):
            return "Step cap exceeded: plan has \(requested) steps, maximum allowed is \(maxSteps)"
        case .aborted(let reason):
            return "Plan execution aborted: \(reason)"
        case .memoryBudgetExceeded(let currentMB, let limitMB):
            return "Memory budget exceeded: \(String(format: "%.1f", currentMB))MB > \(String(format: "%.1f", limitMB))MB"
        }
    }
}

public final class PlanExecutor: @unchecked Sendable {
    public static let shared = PlanExecutor()
    
    public let maxSteps: Int
    public let memoryCeilingMB: Double
    public let jobStore: JobStore
    public let approvalQueue: ApprovalQueue
    public let killSwitch: KillSwitch
    public let policyEngine: PolicyEngine
    public let toolRegistry: ToolRegistry
    public let undoJournal: UndoJournal
    public let memoryReader: (@Sendable () -> Double)?
    public let reportLedger: SubagentReportLedger
    
    public init(
        maxSteps: Int = 8,
        memoryCeilingMB: Double = 45.0,
        jobStore: JobStore = .shared,
        approvalQueue: ApprovalQueue = .shared,
        killSwitch: KillSwitch = .shared,
        policyEngine: PolicyEngine = .shared,
        toolRegistry: ToolRegistry = .shared,
        undoJournal: UndoJournal = .shared,
        memoryReader: (@Sendable () -> Double)? = nil,
        reportLedger: SubagentReportLedger = .shared
    ) {
        self.maxSteps = maxSteps
        self.memoryCeilingMB = memoryCeilingMB
        self.jobStore = jobStore
        self.approvalQueue = approvalQueue
        self.killSwitch = killSwitch
        self.policyEngine = policyEngine
        self.toolRegistry = toolRegistry
        self.undoJournal = undoJournal
        self.memoryReader = memoryReader
        self.reportLedger = reportLedger
    }
    
    public func executePlan(
        goal: String,
        steps: [PlanStep],
        context: ToolExecutionContext = ToolExecutionContext(),
        userPresent: Bool = true,
        strictStepCap: Bool = false,
        archetype: SpecialistArchetype? = nil,
        onStepProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async throws -> PlanJob {
        if steps.count > maxSteps && strictStepCap {
            throw PlanExecutorError.stepCapExceeded(maxSteps: maxSteps, requested: steps.count)
        }
        
        let sliced = Array(steps.prefix(maxSteps))
        let sequentialSteps = sliced.enumerated().map { idx, step in
            PlanStep(
                index: idx,
                description: step.description,
                toolName: step.toolName,
                arguments: step.arguments,
                status: step.status,
                resultMessage: step.resultMessage,
                reversible: step.reversible
            )
        }
        
        var job = try await jobStore.createJob(goal: goal, steps: sequentialSteps)
        job.status = .running
        job.updatedAt = Date()
        try await jobStore.updateJob(job)
        
        _ = try? reportLedger.startReport(jobId: job.id, archetype: archetype, goal: goal)
        return try await runLoop(job: job, context: context, userPresent: userPresent, onStepProgress: onStepProgress)
    }
    
    public func resumeJob(
        id: String,
        context: ToolExecutionContext = ToolExecutionContext(),
        userPresent: Bool = true
    ) async throws -> PlanJob {
        guard var job = try await jobStore.getJob(id: id) else {
            throw PlanExecutorError.jobNotFound(id)
        }
        
        // If current step was pausedForApproval, check if it was resolved in ApprovalQueue
        if job.currentStepIndex < job.steps.count {
            let i = job.currentStepIndex
            if job.steps[i].status == .pausedForApproval {
                let approvals = await approvalQueue.listAll()
                if let matchingApproval = approvals.last(where: { $0.jobId == job.id && $0.toolName == job.steps[i].toolName }) {
                    if matchingApproval.status == .approved {
                        job.steps[i].status = .completed
                        job.steps[i].resultMessage = "Approved and executed via ApprovalQueue"
                        job.currentStepIndex += 1
                    } else if matchingApproval.status == .denied {
                        job.steps[i].status = .failed
                        job.steps[i].resultMessage = "Approval denied: \(matchingApproval.reason)"
                        job.status = .failed
                        job.errorMessage = "Approval denied: \(matchingApproval.reason)"
                        job.updatedAt = Date()
                        try await jobStore.updateJob(job)
                        return job
                    }
                }
            }
        }
        
        if job.currentStepIndex >= job.steps.count {
            job.status = .completed
            job.updatedAt = Date()
            try await jobStore.updateJob(job)
            return job
        }
        
        job.status = .running
        job.errorMessage = nil
        job.updatedAt = Date()
        try await jobStore.updateJob(job)
        
        return try await runLoop(job: job, context: context, userPresent: userPresent, onStepProgress: nil)
    }
    
    public func rollbackJob(id: String) async throws -> Int {
        guard var job = try await jobStore.getJob(id: id) else {
            throw PlanExecutorError.jobNotFound(id)
        }
        
        var revertedCount = 0
        let reversibleSteps = job.steps.filter { $0.status == .completed && $0.reversible }
        for _ in reversibleSteps {
            _ = try await undoJournal.undoLast()
            revertedCount += 1
        }
        
        for i in 0..<job.steps.count {
            if job.steps[i].status == .completed {
                job.steps[i].status = .rolledBack
            }
        }
        job.status = .rolledBack
        job.updatedAt = Date()
        try await jobStore.updateJob(job)
        
        return revertedCount
    }
    
    // MARK: - Execution Loop
    
    private func runLoop(
        job: PlanJob,
        context: ToolExecutionContext,
        userPresent: Bool,
        onStepProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async throws -> PlanJob {
        do {
            let finalJob = try await runLoopCore(
                job: job,
                context: context,
                userPresent: userPresent,
                onStepProgress: onStepProgress
            )
            finalizeLedger(for: finalJob)
            return finalJob
        } catch {
            var failedJob = job
            failedJob.status = .failed
            failedJob.errorMessage = error.localizedDescription
            finalizeLedger(for: failedJob)
            throw error
        }
    }
    
    private func runLoopCore(
        job: PlanJob,
        context: ToolExecutionContext,
        userPresent: Bool,
        onStepProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async throws -> PlanJob {
        var job = job
        
        while job.currentStepIndex < job.steps.count {
            let i = job.currentStepIndex
            var step = job.steps[i]
            let stepStart = Date()
            
            onStepProgress?(i, job.steps.count, step.description)
            
            // 1. Check killSwitch.isAborted
            if killSwitch.isAborted {
                job.status = .aborted
                job.errorMessage = killSwitch.lastReason ?? "Kill switch activated"
                job.updatedAt = Date()
                try await jobStore.updateJob(job)
                return job
            }
            
            // 2. Memory ceiling check
            let currentMem = currentMemoryMB()
            if currentMem > memoryCeilingMB {
                job.status = .pausedForMemory
                job.errorMessage = "Memory ceiling exceeded: \(String(format: "%.1f", currentMem))MB > \(String(format: "%.1f", memoryCeilingMB))MB"
                job.updatedAt = Date()
                try await jobStore.updateJob(job)
                return job
            }
            
            // 3. Lookup tool in toolRegistry (falling back to CentralToolCatalog only on .shared)
            let resolvedTool = toolRegistry.tool(named: step.toolName) ??
                (toolRegistry === ToolRegistry.shared ? CentralToolCatalog.shared.tool(named: step.toolName) : nil)
            guard let tool = resolvedTool else {
                step.status = .failed
                step.resultMessage = "Tool not found in registry: \(step.toolName)"
                job.steps[i] = step
                job.status = .failed
                job.errorMessage = "Tool not found in registry: \(step.toolName)"
                job.updatedAt = Date()
                try await jobStore.updateJob(job)
                appendStepLedger(job: job, index: i, step: step, startedAt: stepStart)
                return job
            }
            
            step.reversible = step.reversible || tool.isReversible
            
            // Check if approval was already recorded for this step
            if step.status == .pausedForApproval {
                let approvals = await approvalQueue.listAll()
                if let matchingApproval = approvals.last(where: { $0.jobId == job.id && $0.toolName == step.toolName }) {
                    if matchingApproval.status == .approved {
                        if matchingApproval.executionSucceeded == true {
                            step.status = .completed
                            step.resultMessage = matchingApproval.executionMessage ?? "Approved and executed via ApprovalQueue"
                            job.steps[i] = step
                            job.currentStepIndex += 1
                            job.updatedAt = Date()
                            try await jobStore.updateJob(job)
                            appendStepLedger(job: job, index: i, step: step, startedAt: stepStart)
                            continue
                        } else if matchingApproval.executionSucceeded == false {
                            step.status = .failed
                            step.resultMessage = matchingApproval.executionMessage ?? "Approved step failed during execution"
                            job.steps[i] = step
                            job.status = .failed
                            job.errorMessage = step.resultMessage
                            job.updatedAt = Date()
                            try await jobStore.updateJob(job)
                            appendStepLedger(job: job, index: i, step: step, startedAt: stepStart)
                            return job
                        } else {
                            // Approved status recorded without prior execution outcome -> execute now with userConfirmed
                            let confirmedCtx = ToolExecutionContext(
                                trustState: .trusted,
                                userConfirmed: true,
                                providerIsLocal: context.providerIsLocal,
                                taintState: context.taintState,
                                freshConfirmationArgs: step.arguments
                            )
                            let execRes = try await policyEngine.execute(tool: tool, args: step.arguments, context: confirmedCtx)
                            if execRes.success {
                                step.status = .completed
                                step.resultMessage = execRes.message
                                job.steps[i] = step
                                job.currentStepIndex += 1
                                job.updatedAt = Date()
                                try await jobStore.updateJob(job)
                                appendStepLedger(job: job, index: i, step: step, startedAt: stepStart)
                                continue
                            } else {
                                step.status = .failed
                                step.resultMessage = execRes.message
                                job.steps[i] = step
                                job.status = .failed
                                job.errorMessage = execRes.message
                                job.updatedAt = Date()
                                try await jobStore.updateJob(job)
                                appendStepLedger(job: job, index: i, step: step, startedAt: stepStart)
                                return job
                            }
                        }
                    } else if matchingApproval.status == .denied {
                        step.status = .failed
                        step.resultMessage = "Approval denied: \(matchingApproval.reason)"
                        job.steps[i] = step
                        job.status = .failed
                        job.errorMessage = "Approval denied: \(matchingApproval.reason)"
                        job.updatedAt = Date()
                        try await jobStore.updateJob(job)
                        appendStepLedger(job: job, index: i, step: step, startedAt: stepStart)
                        return job
                    }
                }
            }
            
            // 4. Policy evaluation & away-mode check
            let decision = policyEngine.evaluate(tool: tool, args: step.arguments, context: context)
            let awayRestricted = (!userPresent && tool.tier >= .t2ReadPersonal)
            
            if case .denied(let reason) = decision {
                step.status = .failed
                step.resultMessage = "Security policy denied action: \(reason)"
                job.steps[i] = step
                job.status = .failed
                job.errorMessage = step.resultMessage
                job.updatedAt = Date()
                try await jobStore.updateJob(job)
                appendStepLedger(job: job, index: i, step: step, startedAt: stepStart)
                return job
            }
            
            var approvalReason: String? = nil
            if case .confirmationRequired(let reason) = decision {
                approvalReason = reason
            } else if awayRestricted {
                approvalReason = "Away mode active (user not present): approval required for \(tool.name) (tier: \(tool.tier.rawValue))"
            }
            
            if let reason = approvalReason {
                let approval = try await approvalQueue.enqueue(
                    toolName: step.toolName,
                    arguments: step.arguments,
                    tier: tool.tier,
                    reason: reason,
                    jobId: job.id
                )
                step.status = .pausedForApproval
                step.resultMessage = "Paused for approval: \(reason) (Approval ID: \(approval.id))"
                job.steps[i] = step
                job.status = .pausedForApproval
                job.updatedAt = Date()
                try await jobStore.updateJob(job)
                appendStepLedger(job: job, index: i, step: step, startedAt: stepStart)
                return job
            }
            
            // 5. Execute step via policyEngine
            do {
                let result = try await policyEngine.execute(tool: tool, args: step.arguments, context: context)
                if result.success {
                    step.status = .completed
                    step.resultMessage = result.message
                    job.steps[i] = step
                    job.currentStepIndex += 1
                    job.updatedAt = Date()
                    try await jobStore.updateJob(job)
                    appendStepLedger(job: job, index: i, step: step, startedAt: stepStart)
                } else {
                    step.status = .failed
                    step.resultMessage = result.message
                    job.steps[i] = step
                    job.status = .failed
                    job.errorMessage = result.message
                    job.updatedAt = Date()
                    try await jobStore.updateJob(job)
                    appendStepLedger(job: job, index: i, step: step, startedAt: stepStart)
                    return job
                }
            } catch {
                step.status = .failed
                step.resultMessage = error.localizedDescription
                job.steps[i] = step
                job.status = .failed
                job.errorMessage = error.localizedDescription
                job.updatedAt = Date()
                try await jobStore.updateJob(job)
                appendStepLedger(job: job, index: i, step: step, startedAt: stepStart)
                return job
            }
        }
        
        // 6. All steps finished cleanly
        job.status = .completed
        job.updatedAt = Date()
        try await jobStore.updateJob(job)
        return job
    }
    
    private func appendStepLedger(job: PlanJob, index: Int, step: PlanStep, startedAt: Date) {
        let elapsedMs = Date().timeIntervalSince(startedAt) * 1000.0
        try? reportLedger.appendStep(
            jobId: job.id,
            stepIndex: index + 1,
            totalSteps: job.steps.count,
            toolName: step.toolName,
            status: step.status.rawValue,
            detail: step.resultMessage ?? step.description,
            durationMs: elapsedMs
        )
    }
    
    private func finalizeLedger(for job: PlanJob) {
        let completedCount = job.steps.filter { $0.status == .completed }.count
        let summary = job.errorMessage ?? "Executed \(completedCount)/\(job.steps.count) steps"
        let verification = job.status == .completed
            ? "All \(job.steps.count) steps completed"
            : "Ended with status \(job.status.rawValue)"
        try? reportLedger.finalizeReport(
            jobId: job.id,
            status: job.status.rawValue,
            summary: summary,
            verification: verification
        )
    }
    
    private func currentMemoryMB() -> Double {
        if let reader = memoryReader {
            return reader()
        }
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            return Double(info.resident_size) / (1024.0 * 1024.0)
        }
        return 0.0
    }
}
