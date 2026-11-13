import Foundation

public enum PolicyDecision: Sendable {
    case allowed
    case confirmationRequired(reason: String)
    case denied(reason: String)
}

public final class PolicyEngine: Sendable {
    public static let shared = PolicyEngine()
    
    public init() {}
    
    public func evaluate(tool: any PearlTool, args: [String: String], context: ToolExecutionContext) -> PolicyDecision {
        // T0 Observe is always safe
        if tool.tier == .t0Observe {
            return .allowed
        }
        
        // Taint tracking: untrusted context cannot perform T3+ actions without explicit confirmation
        if context.trustState == .untrusted && tool.tier >= .t3WorkspaceChanges {
            if !context.userConfirmed {
                return .confirmationRequired(reason: "Context is tainted by external/untrusted content. Confirmation required for \(tool.name).")
            }
        }
        
        // T4 and T5 always require confirmation
        if tool.tier >= .t4ExternalSideEffects && !context.userConfirmed {
            return .confirmationRequired(reason: "Action \(tool.name) has external or irreversible side effects.")
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
                await UndoJournal.shared.register(toolName: tool.name, undoAction: undo)
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
                trust: context.trustState
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
                trust: context.trustState
            )
        }
    }
}
