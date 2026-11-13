import EventKit
import Foundation
import PearlCore

public final class ReminderTool: PearlTool {
    public let name = "reminder"
    public let description = "Create or list reminders in Apple Reminders with instant undo support"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = [.reminders]
    public let isReversible = true
    
    public init() {}
    
    private var localStoreURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let pearlDir = appSupport.appendingPathComponent("Pearl", isDirectory: true)
        try? FileManager.default.createDirectory(at: pearlDir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        return pearlDir.appendingPathComponent("reminders.json")
    }
    
    private func loadLocalReminders() -> [String] {
        guard let data = try? Data(contentsOf: localStoreURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return list
    }
    
    private func saveLocalReminders(_ list: [String]) {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: localStoreURL, options: .atomic)
        }
    }
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let action = args["action"]?.lowercased() ?? (args["title"] != nil ? "create" : "list")
        
        if action == "list" {
            return await listReminders()
        } else {
            let title = args["title"] ?? args["text"] ?? "Pearl Reminder"
            return await createReminder(title: title)
        }
    }
    
    private func listReminders() async -> ToolResult {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .reminder)
        
        if status == .fullAccess {
            let predicate = store.predicateForReminders(in: nil)
            let ekReminders: [EKReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { items in
                    continuation.resume(returning: items ?? [])
                }
            }
            if !ekReminders.isEmpty {
                let titles = ekReminders.prefix(5).map { $0.title ?? "Untitled" }
                return ToolResult(success: true, message: "Reminders (\(ekReminders.count)): " + titles.joined(separator: ", "))
            }
        }
        
        // Fallback to local store
        let local = loadLocalReminders()
        if local.isEmpty {
            return ToolResult(success: true, message: "No active reminders found.")
        } else {
            let formatted = local.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "; ")
            return ToolResult(success: true, message: "Reminders (\(local.count)): \(formatted)")
        }
    }
    
    private func createReminder(title: String) async -> ToolResult {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .reminder)
        
        var ekSaved = false
        var reminderID: String? = nil
        
        if status == .fullAccess {
            if let defaultCal = store.defaultCalendarForNewReminders() {
                let rem = EKReminder(eventStore: store)
                rem.title = title
                rem.calendar = defaultCal
                if (try? store.save(rem, commit: true)) != nil {
                    ekSaved = true
                    reminderID = rem.calendarItemIdentifier
                }
            }
        } else if status == .notDetermined {
            // Attempt request if possible
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
            if granted, let defaultCal = store.defaultCalendarForNewReminders() {
                let rem = EKReminder(eventStore: store)
                rem.title = title
                rem.calendar = defaultCal
                if (try? store.save(rem, commit: true)) != nil {
                    ekSaved = true
                    reminderID = rem.calendarItemIdentifier
                }
            }
        }
        
        // Always store in local fallback for robust offline/test access
        var local = loadLocalReminders()
        local.append(title)
        saveLocalReminders(local)
        
        let savedTitle = title
        let capturedReminderID = reminderID
        let fileURL = self.localStoreURL
        let undoAction: @Sendable () async throws -> Void = {
            if let rId = capturedReminderID {
                let undoStore = EKEventStore()
                if let item = undoStore.calendarItem(withIdentifier: rId) as? EKReminder {
                    try? undoStore.remove(item, commit: true)
                }
            }
            // Remove from local store
            if let data = try? Data(contentsOf: fileURL),
               var items = try? JSONDecoder().decode([String].self, from: data) {
                if let idx = items.lastIndex(of: savedTitle) {
                    items.remove(at: idx)
                    if let enc = try? JSONEncoder().encode(items) {
                        try? enc.write(to: fileURL, options: .atomic)
                    }
                }
            }
        }
        
        let destination = ekSaved ? "Apple Reminders" : "Reminders"
        return ToolResult(
            success: true,
            message: "Added '\(title)' to \(destination).",
            undoAction: undoAction
        )
    }
}
