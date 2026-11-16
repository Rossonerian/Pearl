import Foundation

public enum PolicyDecision: Sendable {
    case allowed
    case confirmationRequired(reason: String)
    case denied(reason: String)
}

public final class PolicyEngine: Sendable {
    public static let shared = PolicyEngine()
    public let undoJournal: UndoJournal
    
    public init(undoJournal: UndoJournal = .shared) {
        self.undoJournal = undoJournal
    }
    
    public func evaluate(tool: any PearlTool, args: [String: String], context: ToolExecutionContext) -> PolicyDecision {
        // 1. Never-Tier validation: hard-blocked commands and paths
        let neverResult = NeverTierValidator.checkTool(tool: tool, args: args)
        if neverResult.isDenied {
            return .denied(reason: neverResult.reason ?? "Never-Tier rule violation")
        }
        
        // 2. T0 Observe is always safe
        if tool.tier == .t0Observe {
            return .allowed
        }
        
        // 3. Taint tracking evaluation
        let effectiveTaint = context.taintState.isTainted ? context.taintState : TaintTracker.shared.currentState
        if effectiveTaint.isTainted {
            let taintDecision = TaintTracker.shared.evaluate(
                tool: tool,
                args: args,
                providerIsLocal: context.providerIsLocal,
                userConfirmed: context.userConfirmed,
                freshConfirmationArgs: context.freshConfirmationArgs,
                explicitTaintState: effectiveTaint
            )
            if case .allowed = taintDecision {
                // allowed under taint rules, proceed to standard checks
            } else {
                return taintDecision
            }
        }
        
        let isConfirmed = context.userConfirmed
        if isConfirmed {
            if let confirmedTool = context.freshConfirmationToolName,
               !confirmedTool.isEmpty,
               confirmedTool.lowercased() != tool.name.lowercased() {
                return .confirmationRequired(reason: "Tool action modified from '\(confirmedTool)' to '\(tool.name)' after confirmation prompt. Re-confirmation required.")
            }
            if let confirmedArgs = context.freshConfirmationArgs, confirmedArgs != args {
                return .confirmationRequired(reason: "Action arguments modified after confirmation prompt for '\(tool.name)'. Re-confirmation required.")
            }
        }
        
        // 4. Untrusted context cannot perform T3+ actions without explicit user confirmation
        if context.trustState == .untrusted && tool.tier >= .t3WorkspaceChanges {
            if !context.userConfirmed {
                return .confirmationRequired(reason: "Context is tainted by external/untrusted content. Confirmation required for \(tool.name).")
            }
        }
        
        // 5. T4 and T5 always require confirmation
        if tool.tier >= .t4ExternalSideEffects && !isConfirmed {
            return .confirmationRequired(reason: "Action \(tool.name) has external or irreversible side effects.")
        }
        
        // 6. Enforce ToolMetadata.requiresConfirmation on T1-T3 tools (e.g. delete_task, trash_file, rename_file, move_file)
        if let meta = CentralToolCatalog.shared.metadata(for: tool.name),
           meta.requiresConfirmation,
           !isConfirmed {
            return .confirmationRequired(reason: "Action '\(tool.name)' requires user confirmation before execution.")
        }
        
        return .allowed
    }
    
    public func execute(
        tool: any PearlTool,
        args: [String: String],
        context: ToolExecutionContext
    ) async throws -> ToolResult {
        let decision = evaluate(tool: tool, args: args, context: context)
        
        switch decision {
        case .allowed:
            let result = try await tool.execute(args: args, context: context)
            
            // Audit log every execution
            await AuditLogger.shared.log(
                tool: tool.name,
                args: args,
                tier: tool.tier,
                trustState: context.trustState,
                success: result.success
            )
            
            // If tool produced an undo action, register with UndoJournal
            if let undo = result.undoAction {
                await undoJournal.register(toolName: tool.name, undoAction: undo)
            }
            
            return result
            
        case .confirmationRequired(let reason):
            await AuditLogger.shared.log(
                tool: tool.name,
                args: args,
                tier: tool.tier,
                trustState: context.trustState,
                success: false
            )
            return ToolResult(
                success: false,
                message: "Confirmation required: \(reason)",
                trust: context.trustState,
                errorCode: .permissionDenied
            )
            
        case .denied(let reason):
            await AuditLogger.shared.log(
                tool: tool.name,
                args: args,
                tier: tool.tier,
                trustState: context.trustState,
                success: false
            )
            return ToolResult(
                success: false,
                message: "Action denied by security policy: \(reason)",
                trust: context.trustState,
                errorCode: .permissionDenied
            )
        }
    }
}
