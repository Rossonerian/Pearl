import Foundation
import PearlCore

public final class UndoTool: PearlTool {
    public let name = "undo"
    public let description = "Reverses the most recent action recorded in the Undo Journal"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        do {
            let msg = try await UndoJournal.shared.undoLast()
            return ToolResult(success: true, message: msg)
        } catch {
            return ToolResult(success: false, message: "Undo failed: \(error.localizedDescription)")
        }
    }
}
