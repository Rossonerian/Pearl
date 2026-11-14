import Foundation
import PearlCore

// Re-export core task tools for PearlTools module consumers
public typealias ListTasksTool = PearlCore.ListTasksTool
public typealias CreateTaskTool = PearlCore.CreateTaskTool
public typealias CompleteTaskTool = PearlCore.CompleteTaskTool
public typealias DeleteTaskTool = PearlCore.DeleteTaskTool

extension CentralToolCatalog {
    /// Registers all task execution tools (list_tasks, create_task, complete_task, delete_task)
    /// into CentralToolCatalog with comprehensive metadata.
    public func registerTaskTools() {
        register(ListTasksTool())
        register(CreateTaskTool())
        register(CompleteTaskTool())
        register(DeleteTaskTool())
    }
}

extension ToolRegistry {
    /// Registers all task execution tools into ToolRegistry.
    public func registerTaskTools() {
        register(ListTasksTool())
        register(CreateTaskTool())
        register(CompleteTaskTool())
        register(DeleteTaskTool())
    }
}
