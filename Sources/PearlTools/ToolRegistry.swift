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
            CreateDirectoryTool(),
            ListDirectoryTool(),
            RenameFileTool(),
            TrashFileTool(),
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
            
            // Skills, Recipes & Proposals
            ProposeSkillTool(),
            UseRecipeTool(),
            SearchSkillCatalogTool(),
            
            // SubBots & Autonomous Web Operations
            SubBotRunTool(),
            SubBotWorkflowTool(),
            
            // Obsidian Brain Vault & Atomic Output
            VaultListTool(),
            VaultReadTool(),
            VaultWriteTool(),
            VaultSearchTool(),
            OutputFileTool(),
            
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
            registry.register(tool)
            catalog.register(tool)
        }
    }

    /// Bootstraps all PearlTools and core task tools into both the provided `ToolRegistry` and `CentralToolCatalog`.
    public static func bootstrapAllTools(
        into registry: ToolRegistry = .shared,
        catalog: CentralToolCatalog = .shared
    ) {
        registerAll(into: registry, catalog: catalog)
        registry.registerTaskTools()
        catalog.registerDefaultCoreTools()
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
