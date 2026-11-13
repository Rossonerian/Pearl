import EventKit
import Foundation
import PearlCore

public final class ReminderTool: PearlTool {
    public let name = "reminder"
    public let description = "Create a reminder in Apple Reminders with instant undo support"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = [.reminders]
    public let isReversible = true
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let title = args["title"], !title.isEmpty else {
            return ToolResult(success: false, message: "Missing reminder title.")
        }
        
        let store = EKEventStore()
        
        // Check / request authorization
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status != .fullAccess {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = (try? await store.requestFullAccessToReminders()) ?? false
            } else {
                granted = await withCheckedContinuation { continuation in
                    store.requestAccess(to: .reminder) { ok, _ in
                        continuation.resume(returning: ok)
                    }
                }
            }
            guard granted else {
                return ToolResult(success: false, message: "Reminders permission denied by system.")
            }
        }
        
        guard let defaultCalendar = store.defaultCalendarForNewReminders() else {
            return ToolResult(success: false, message: "No default Reminders list available.")
        }
        
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = defaultCalendar
        
        do {
            try store.save(reminder, commit: true)
            let reminderID = reminder.calendarItemIdentifier
            
            let undoAction: @Sendable () async throws -> Void = {
                let undoStore = EKEventStore()
                if let item = undoStore.calendarItem(withIdentifier: reminderID) as? EKReminder {
                    try? undoStore.remove(item, commit: true)
                }
            }
            
            return ToolResult(
                success: true,
                message: "Added '\(title)' to Reminders.",
                undoAction: undoAction
            )
        } catch {
            return ToolResult(success: false, message: "Failed to save reminder: \(error.localizedDescription)")
        }
    }
}
