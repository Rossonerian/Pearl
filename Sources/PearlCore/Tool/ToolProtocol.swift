import Foundation

public enum ToolTier: Int, Codable, Comparable, Sendable {
    case t0Observe = 0
    case t1Reversible = 1
    case t2ReadPersonal = 2
    case t3WorkspaceChanges = 3
    case t4ExternalSideEffects = 4
    case t5RawShell = 5
    
    public static func < (lhs: ToolTier, rhs: ToolTier) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

public enum TrustLevel: String, Codable, Sendable {
    case trusted
    case untrusted
}

public enum TCCService: String, Codable, Sendable {
    case none
    case reminders
    case calendar
    case screenRecording
    case accessibility
    case contacts
}

public struct ToolExecutionContext: Sendable {
    public let trustState: TrustLevel
    public let userConfirmed: Bool
    public let providerIsLocal: Bool
    public let taintState: TaintState
    public let freshConfirmationArgs: [String: String]?
    
    public init(
        trustState: TrustLevel = .trusted,
        userConfirmed: Bool = false,
        providerIsLocal: Bool = false,
        taintState: TaintState = .clean,
        freshConfirmationArgs: [String: String]? = nil
    ) {
        self.trustState = taintState.isTainted ? .untrusted : trustState
        self.userConfirmed = userConfirmed
        self.providerIsLocal = providerIsLocal
        self.taintState = taintState
        self.freshConfirmationArgs = freshConfirmationArgs
    }
}

public struct ToolResult: Sendable {
    public let success: Bool
    public let message: String
    public let trust: TrustLevel
    public let undoAction: (@Sendable () async throws -> Void)?
    
    public init(
        success: Bool,
        message: String,
        trust: TrustLevel = .trusted,
        undoAction: (@Sendable () async throws -> Void)? = nil
    ) {
        self.success = success
        self.message = message
        self.trust = trust
        self.undoAction = undoAction
    }
}

public protocol PearlTool: Sendable {
    var name: String { get }
    var description: String { get }
    var tier: ToolTier { get }
    var requiredTCC: [TCCService] { get }
    var isReversible: Bool { get }
    var argumentDescriptors: [ToolArgumentDescriptor] { get }
    
    func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult
}

extension PearlTool {
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return []
    }
}
