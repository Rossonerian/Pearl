import Foundation
import PearlCore

/// Central tool registry catalog for PearlTools framework.
public struct PearlToolsRegistry {
    
    /// Returns instances of all native macOS tools provided by PearlTools.
    public static func allTools() -> [any PearlTool] {
        return [
            // Hardware & System Context
            BatteryTool(),
            VolumeTool(),
            GetDisplayInfoTool(),
            DisplayContextTool(),
            
            // App & Window Management
            AppTool(),
            CloseAppTool(),
            FrontmostAppTool(),
            
            // Screen & Storage
            ScreenshotTool(),
            TrashScreenshotsTool(),
            
            // Version Control
            GitTool(),
            GitStatusTool(),
            
            // Reminders & Calendar
            ReminderTool(),
            ListCalendarEventsTool(),
            CheckCalendarAvailabilityTool(),
            CreateCalendarEventTool(),
            DeleteCalendarEventTool(),
            CalendarTool(),
            
            // Clipboard & Pasteboard
            ReadClipboardTool(),
            WriteClipboardTool(),
            ClipboardTool(),
            
            // Notifications & UI
            PostNotificationTool(),
            NotificationTool(),
            
            // History & Rollback
            UndoTool(),
            
            // File & Directory Operations (Allowlisted & Quarantined)
            SearchFilesTool(),
            ReadFileSafeTool(),
            CopyFileTool(),
            MoveFileTool(),
            
            // Window Management
            ListWindowsTool(),
            ManageWindowTool(),
            
            // Shortcuts
            ListShortcutsTool(),
            RunShortcutTool(),
            
            // Browser Operations
            ListBrowserTabsTool(),
            OpenURLTool(),
            ReadActiveTabTool(),
            
            // SubBots & Autonomous Web Operations
            SubBotRunTool(),
            SubBotWorkflowTool(),
            
            // Communication & Mail Drafts
            CreateMailDraftTool(),
            SendMailTool(),
            
            // Screen OCR (In-Memory)
            ScreenReadTool()
        ]
    }
    
    /// Registers all standard native tools into the provided `ToolRegistry` and `CentralToolCatalog`.
    public static func registerAll(
        into registry: ToolRegistry = .shared,
        catalog: CentralToolCatalog = .shared
    ) {
        for tool in allTools() {
            catalog.register(tool)
        }
    }
}

public extension ToolRegistry {
    /// Registers all standard native tools from PearlTools into this `ToolRegistry`.
    func registerDefaultPearlTools() {
        PearlToolsRegistry.registerAll(into: self, catalog: .shared)
    }
}

public extension CentralToolCatalog {
    /// Registers all standard native tools from PearlTools into this `CentralToolCatalog`.
    func registerDefaultPearlTools() {
        PearlToolsRegistry.registerAll(into: .shared, catalog: self)
    }
}
