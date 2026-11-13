import Foundation

/// Represents the taint status of the agent conversation context.
public enum TaintState: Equatable, Sendable {
    case clean
    case tainted(source: String, reason: String)
    
    public var isTainted: Bool {
        switch self {
        case .clean: return false
        case .tainted: return true
        }
    }
    
    public var source: String? {
        switch self {
        case .clean: return nil
        case .tainted(let src, _): return src
        }
    }
    
    public var reason: String? {
        switch self {
        case .clean: return nil
        case .tainted(_, let r): return r
        }
    }
}

/// Tracks context taint state across external inputs (mail, web, untrusted files, MCP tools).
/// Enforces safety policies to prevent indirect prompt injection and data exfiltration.
public final class TaintTracker: @unchecked Sendable {
    public static let shared = TaintTracker()
    
    private var _state: TaintState = .clean
    private let lock = NSLock()
    
    public init() {}
    
    /// Current taint status of the context
    public var currentState: TaintState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }
    
    /// Tags context as tainted due to ingestion of external untrusted content.
    ///
    /// - Parameters:
    ///   - source: The origin of untrusted content ("mail", "web", "file", "mcp").
    ///   - reason: Detailed description of why content is untrusted.
    public func markTainted(source: String, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        _state = .tainted(source: source, reason: reason)
    }
    
    /// Clears taint state when a new clean turn/conversation begins.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _state = .clean
    }
    
    /// Helper to determine if an argument contains external network target URLs (potential exfiltration).
    public static func containsExfiltrationURL(args: [String: String]) -> Bool {
        for (_, val) in args {
            let lower = val.lowercased()
            if lower.contains("http://") || lower.contains("https://") {
                return true
            }
        }
        return false
    }
    
    /// Evaluates taint-specific policy rules on an intended tool action.
    ///
    /// Enforces:
    /// 1. Local models cannot execute T3+ tools while context is tainted.
    /// 2. Any T3+ tool action requires fresh explicit user confirmation showing exact arguments.
    /// 3. Exfiltration URL fetches are strictly blocked without fresh user confirmation.
    public func evaluate(
        tool: any PearlTool,
        args: [String: String],
        providerIsLocal: Bool,
        userConfirmed: Bool,
        freshConfirmationArgs: [String: String]? = nil
    ) -> PolicyDecision {
        let state = currentState
        
        guard case .tainted(let source, let reason) = state else {
            return .allowed
        }
        
        // 1. Local model cannot execute T3+ tools in tainted context
        if providerIsLocal && tool.tier >= .t3WorkspaceChanges {
            return .denied(
                reason: "Local model cannot execute T3+ action '\(tool.name)' while context is tainted by \(source): \(reason). Escalation to confirmed planner required."
            )
        }
        
        // 2. Exfiltration URL fetches are blocked without confirmation
        if TaintTracker.containsExfiltrationURL(args: args) && !userConfirmed {
            return .confirmationRequired(
                reason: "Exfiltration URL fetch blocked in context tainted by \(source). Explicit user confirmation required showing exact destination: \(args)"
            )
        }
        
        // 3. ANY T3+ tool action requires fresh explicit user confirmation showing exact arguments
        if tool.tier >= .t3WorkspaceChanges {
            if !userConfirmed {
                return .confirmationRequired(
                    reason: "Context is tainted by \(source) ('\(reason)'). Fresh explicit user confirmation required for '\(tool.name)' showing exact arguments: \(args)"
                )
            }
            
            // If confirmation was granted, verify arguments have not drifted
            if let confirmedArgs = freshConfirmationArgs, confirmedArgs != args {
                return .confirmationRequired(
                    reason: "Action arguments modified after confirmation. Re-confirmation required for '\(tool.name)' showing exact arguments: \(args)"
                )
            }
        }
        
        return .allowed
    }
}
