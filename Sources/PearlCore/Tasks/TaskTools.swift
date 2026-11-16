import Foundation

// MARK: - ListTasksTool (Tier T0 Observe)

public final class ListTasksTool: PearlTool {
    public let name = "list_tasks"
    public let description = "List active tasks formatted cleanly, optionally filtered by status and priority"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "status",
                type: "string",
                description: "Filter by status: pending, completed, cancelled, or all (default: pending)",
                isRequired: false,
                allowedValues: ["pending", "completed", "cancelled", "all"]
            ),
            ToolArgumentDescriptor(
                name: "priority",
                type: "string",
                description: "Filter by priority: low, medium, high, urgent",
                isRequired: false,
                allowedValues: ["low", "medium", "high", "urgent"]
            )
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let statusArg = args["status"]?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let priorityArg = args["priority"]?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        let statusFilter: TaskStatus?
        if statusArg == "all" {
            statusFilter = nil
        } else if let s = statusArg, !s.isEmpty {
            statusFilter = TaskStatus.fromString(s)
        } else {
            // Default to pending tasks
            statusFilter = .pending
        }
        
        let priorityFilter: TaskPriority?
        if let p = priorityArg, !p.isEmpty {
            priorityFilter = TaskPriority(rawValue: p)
        } else {
            priorityFilter = nil
        }
        
        do {
            let tasks = try await TaskStore.shared.listTasks(status: statusFilter, priority: priorityFilter)
            
            if tasks.isEmpty {
                let filterDesc = [
                    statusFilter != nil ? "\(statusFilter!.displayName.lowercased())" : "any status",
                    priorityFilter != nil ? "[\(priorityFilter!.displayName.lowercased()) priority]" : ""
                ].filter { !$0.isEmpty }.joined(separator: " ")
                
                return ToolResult(
                    success: true,
                    message: "No tasks found matching criteria (\(filterDesc))."
                )
            }
            
            var lines: [String] = []
            let countHeader = "\(tasks.count) \(statusFilter?.displayName.lowercased() ?? "active") task(s)"
            lines.append("📋 Pearl Tasks (\(countHeader)):")
            
            for (idx, task) in tasks.enumerated() {
                var taskLine = "\(idx + 1). \(task.priority.badge) \(task.title)"
                
                if let due = task.dueDate {
                    let dueStr = TaskDateFormatter.displayString(from: due)
                    if task.isOverdue() {
                        taskLine += " (⚠️ Overdue: \(dueStr))"
                    } else {
                        taskLine += " (Due: \(dueStr))"
                    }
                }
                
                if task.status != .pending {
                    taskLine += " [\(task.status.displayName)]"
                }
                
                taskLine += " [ID: \(task.id.uuidString.prefix(8))]"
                lines.append(taskLine)
                
                if let notes = task.notes, !notes.isEmpty {
                    lines.append("     Notes: \(notes)")
                }
            }
            
            return ToolResult(
                success: true,
                message: lines.joined(separator: "\n")
            )
        } catch {
            return ToolResult(
                success: false,
                message: "Failed to list tasks: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - CreateTaskTool (Tier T1 Reversible)

public final class CreateTaskTool: PearlTool {
    public let name = "create_task"
    public let description = "Add a new task with priority and optional due date, with instant undo support"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = []
    public let isReversible = true
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "title",
                type: "string",
                description: "Title of the task to create",
                isRequired: true
            ),
            ToolArgumentDescriptor(
                name: "notes",
                type: "string",
                description: "Optional notes or details for the task",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "priority",
                type: "string",
                description: "Priority: low, medium, high, urgent (default: medium)",
                isRequired: false,
                allowedValues: ["low", "medium", "high", "urgent"]
            ),
            ToolArgumentDescriptor(
                name: "due_date",
                type: "string",
                description: "Due date in ISO-8601 format (e.g. 2026-11-14T18:00:00Z or 2026-11-14)",
                isRequired: false
            )
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let title = args["title"] ?? args["text"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(success: false, message: "Task title cannot be empty.")
        }
        
        let notes = args["notes"] ?? args["description"]
        let priority = TaskPriority.fromString(args["priority"])
        let dueDate = TaskDateFormatter.parseDate(args["due_date"] ?? args["dueDate"])
        
        do {
            let task = try await TaskStore.shared.createTask(
                title: title,
                notes: notes,
                priority: priority,
                dueDate: dueDate
            )
            
            // Register undo action: permanently delete the task created
            let createdId = task.id
            let undoAction: @Sendable () async throws -> Void = {
                _ = try await TaskStore.shared.deleteTask(id: createdId)
                await BriefingEngine.shared.cancelDeadlineNotification(taskId: createdId)
            }
            await UndoJournal.shared.register(toolName: self.name, undoAction: undoAction)
            
            // If due date is set, schedule event-driven notification (0.0% idle CPU)
            if task.dueDate != nil {
                _ = await BriefingEngine.shared.scheduleDeadlineNotification(for: task)
            }
            
            return ToolResult(
                success: true,
                message: "Created task: \(task.formattedSummary)",
                undoAction: undoAction
            )
        } catch {
            return ToolResult(
                success: false,
                message: "Failed to create task: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - CompleteTaskTool (Tier T1 Reversible)

public final class CompleteTaskTool: PearlTool {
    public let name = "complete_task"
    public let description = "Mark an active task as completed with instant undo support"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = []
    public let isReversible = true
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "id",
                type: "string",
                description: "UUID, 8-character ID prefix, or title of the task to mark completed",
                isRequired: true
            )
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let identifier = args["id"] ?? args["title"] ?? args["task"],
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(success: false, message: "Task ID or title is required.")
        }
        
        do {
            guard let task = try await TaskStore.shared.findTask(byIdentifier: identifier) else {
                return ToolResult(success: false, message: "Task '\(identifier)' not found.")
            }
            
            guard let completed = try await TaskStore.shared.completeTask(id: task.id) else {
                return ToolResult(success: false, message: "Could not mark task '\(task.title)' as completed.")
            }
            
            // Cancel deadline notification if active
            await BriefingEngine.shared.cancelDeadlineNotification(taskId: task.id)
            
            // Register undo action: revert status back to pending
            let taskId = task.id
            let undoAction: @Sendable () async throws -> Void = {
                _ = try await TaskStore.shared.uncompleteTask(id: taskId)
                if let restored = try? await TaskStore.shared.getTask(id: taskId), restored.dueDate != nil {
                    _ = await BriefingEngine.shared.scheduleDeadlineNotification(for: restored)
                }
            }
            await UndoJournal.shared.register(toolName: self.name, undoAction: undoAction)
            
            return ToolResult(
                success: true,
                message: "Completed task: \(completed.formattedSummary)",
                undoAction: undoAction
            )
        } catch {
            return ToolResult(
                success: false,
                message: "Failed to complete task: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - DeleteTaskTool (Tier T2 Irreversible, Requires Confirmation)

public final class DeleteTaskTool: PearlTool {
    public let name = "delete_task"
    public let description = "Permanently delete a task by ID or title. Requires user confirmation."
    public let tier = ToolTier.t2ReadPersonal
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "id",
                type: "string",
                description: "UUID, 8-character ID prefix, or title of the task to delete",
                isRequired: true
            ),
            ToolArgumentDescriptor(
                name: "confirm",
                type: "string",
                description: "Pass 'true' to confirm irreversible deletion",
                isRequired: false
            )
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let identifier = args["id"] ?? args["title"] ?? args["task"],
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(success: false, message: "Task ID or title is required.")
        }
        
        do {
            guard let task = try await TaskStore.shared.findTask(byIdentifier: identifier) else {
                return ToolResult(success: false, message: "Task '\(identifier)' not found.")
            }
            
            let isExplicitlyConfirmed = context.userConfirmed
            if !isExplicitlyConfirmed {
                return ToolResult(
                    success: false,
                    message: "Confirmation required: Deleting task '\(task.title)' [ID: \(task.id.uuidString.prefix(8))] is irreversible. Confirm via HUD prompt or --confirm."
                )
            }
            
            guard let deleted = try await TaskStore.shared.deleteTask(id: task.id) else {
                return ToolResult(success: false, message: "Failed to delete task '\(task.title)'.")
            }
            
            await BriefingEngine.shared.cancelDeadlineNotification(taskId: task.id)
            
            return ToolResult(
                success: true,
                message: "Permanently deleted task: '\(deleted.title)' [ID: \(deleted.id.uuidString.prefix(8))]."
            )
        } catch {
            return ToolResult(
                success: false,
                message: "Failed to delete task: \(error.localizedDescription)"
            )
        }
    }
}
