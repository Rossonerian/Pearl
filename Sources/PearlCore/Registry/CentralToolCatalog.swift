import Foundation

/// Descriptor for a tool argument specifying its name, expected data type, and requirements.
public struct ToolArgumentDescriptor: Sendable, Codable, Equatable {
    public let name: String
    public let type: String
    public let description: String
    public let isRequired: Bool
    public let allowedValues: [String]?
    
    public init(
        name: String,
        type: String = "string",
        description: String,
        isRequired: Bool = false,
        allowedValues: [String]? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
        self.allowedValues = allowedValues
    }
}

/// Comprehensive metadata defining a registered tool's operational envelope,
/// risk classification, interface exposure, and security requirements.
public struct ToolMetadata: Sendable {
    public let name: String
    public let description: String
    public let arguments: [ToolArgumentDescriptor]
    public let tier: ToolTier
    public let requiredTCC: [TCCService]
    public let isReversible: Bool
    public let requiresConfirmation: Bool
    public let timeoutSeconds: Double
    public let supportsUndo: Bool
    public let nativeAssistantExposed: Bool
    public let cliExposed: Bool
    public let mcpExposed: Bool
    
    public init(
        name: String,
        description: String,
        arguments: [ToolArgumentDescriptor] = [],
        tier: ToolTier,
        requiredTCC: [TCCService] = [],
        isReversible: Bool,
        requiresConfirmation: Bool? = nil,
        timeoutSeconds: Double = 15.0,
        supportsUndo: Bool? = nil,
        nativeAssistantExposed: Bool = true,
        cliExposed: Bool = true,
        mcpExposed: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.arguments = arguments
        self.tier = tier
        self.requiredTCC = requiredTCC
        self.isReversible = isReversible
        self.requiresConfirmation = requiresConfirmation ?? (tier >= .t3WorkspaceChanges)
        self.timeoutSeconds = timeoutSeconds
        self.supportsUndo = supportsUndo ?? isReversible
        self.nativeAssistantExposed = nativeAssistantExposed
        self.cliExposed = cliExposed
        self.mcpExposed = mcpExposed ?? (tier <= .t2ReadPersonal)
    }
}

/// Central catalog providing a single source of truth for all registered tools,
/// schemas, tiers, reversibility guarantees, and interface exposure policies.
public final class CentralToolCatalog: @unchecked Sendable {
    public static let shared = CentralToolCatalog(isSharedInstance: true)
    
    private var tools: [String: any PearlTool] = [:]
    private var metadataMap: [String: ToolMetadata] = [:]
    private let lock = NSLock()
    private let isSharedInstance: Bool
    
    public convenience init() {
        self.init(isSharedInstance: false)
    }
    
    private init(isSharedInstance: Bool) {
        self.isSharedInstance = isSharedInstance
        registerCanonicalMetadata()
        registerDefaultCoreTools()
    }
    
    /// Pre-populates the catalog with canonical metadata for standard native macOS capability tools.
    public func registerCanonicalMetadata() {
        lock.lock()
        defer { lock.unlock() }
        
        let canonicalList: [ToolMetadata] = [
            ToolMetadata(
                name: "list_calendar_events",
                description: "List calendar events for a time window (e.g. today, tomorrow, next N days)",
                arguments: [
                    ToolArgumentDescriptor(name: "time_window", description: "Time window (today, tomorrow, this week, next N days)"),
                    ToolArgumentDescriptor(name: "start_date", description: "Start date/time (ISO 8601 or yyyy-MM-dd HH:mm)"),
                    ToolArgumentDescriptor(name: "end_date", description: "End date/time (ISO 8601 or yyyy-MM-dd HH:mm)")
                ],
                tier: .t0Observe,
                requiredTCC: [.calendar],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: true
            ),
            ToolMetadata(
                name: "check_calendar_availability",
                description: "Check for schedule conflicts within a specific date/time range",
                arguments: [
                    ToolArgumentDescriptor(name: "start_date", description: "Proposed slot start date/time", isRequired: true),
                    ToolArgumentDescriptor(name: "end_date", description: "Proposed slot end date/time"),
                    ToolArgumentDescriptor(name: "duration", description: "Slot duration (e.g. 30m, 1h)")
                ],
                tier: .t0Observe,
                requiredTCC: [.calendar],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: true
            ),
            ToolMetadata(
                name: "create_calendar_event",
                description: "Create calendar event with title, startDate, endDate, location, notes with instant undo",
                arguments: [
                    ToolArgumentDescriptor(name: "title", description: "Event title or summary", isRequired: true),
                    ToolArgumentDescriptor(name: "start_date", description: "Start date/time", isRequired: true),
                    ToolArgumentDescriptor(name: "end_date", description: "End date/time"),
                    ToolArgumentDescriptor(name: "duration", description: "Event duration"),
                    ToolArgumentDescriptor(name: "location", description: "Physical location or URL"),
                    ToolArgumentDescriptor(name: "notes", description: "Notes or description")
                ],
                tier: .t1Reversible,
                requiredTCC: [.calendar],
                isReversible: true,
                requiresConfirmation: false,
                supportsUndo: true,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: true
            ),
            ToolMetadata(
                name: "delete_calendar_event",
                description: "Cancel or delete a calendar event by ID or title (requires explicit confirmation)",
                arguments: [
                    ToolArgumentDescriptor(name: "id", description: "Event ID to delete"),
                    ToolArgumentDescriptor(name: "title", description: "Event title to delete"),
                    ToolArgumentDescriptor(name: "confirm", description: "Confirmation flag ('true')")
                ],
                tier: .t2ReadPersonal,
                requiredTCC: [.calendar],
                isReversible: false,
                requiresConfirmation: true,
                supportsUndo: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: true
            ),
            ToolMetadata(
                name: "get_display_info",
                description: "Inspect NSScreen and CoreGraphics to report active display resolution, nominal refresh rate, scale factor, and color appearance",
                arguments: [
                    ToolArgumentDescriptor(name: "detailed", description: "Include all displays")
                ],
                tier: .t0Observe,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: true
            ),
            ToolMetadata(
                name: "read_clipboard",
                description: "Read NSPasteboard content, automatically redacting detected secrets",
                arguments: [
                    ToolArgumentDescriptor(name: "max_length", description: "Maximum characters to read")
                ],
                tier: .t0Observe,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: true
            ),
            ToolMetadata(
                name: "write_clipboard",
                description: "Write text to NSPasteboard, saving previous clipboard content in UndoJournal to restore on undo",
                arguments: [
                    ToolArgumentDescriptor(name: "text", description: "Text content to write", isRequired: true)
                ],
                tier: .t1Reversible,
                requiredTCC: [],
                isReversible: true,
                requiresConfirmation: false,
                supportsUndo: true,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: true
            ),
            ToolMetadata(
                name: "post_notification",
                description: "Post a native system notification via UserNotifications or NSUserNotification",
                arguments: [
                    ToolArgumentDescriptor(name: "title", description: "Notification title"),
                    ToolArgumentDescriptor(name: "message", description: "Notification message", isRequired: true),
                    ToolArgumentDescriptor(name: "subtitle", description: "Optional subtitle"),
                    ToolArgumentDescriptor(name: "sound", description: "Play sound ('true')")
                ],
                tier: .t0Observe,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: true
            ),
            
            // Expanded macOS Capability Tools (V3.1 - mcpExposed: false)
            ToolMetadata(
                name: "create_directory",
                description: "Create a new folder at the specified approved path with verification and safe empty-only undo",
                arguments: [
                    ToolArgumentDescriptor(name: "path", description: "Absolute or user-relative target directory path (e.g. ~/Desktop/Pearl)", isRequired: true),
                    ToolArgumentDescriptor(name: "recursive", description: "Create missing intermediate parent directories ('true'/'false')"),
                    ToolArgumentDescriptor(name: "create_if_missing", description: "Idempotently succeed if directory already exists ('true'/'false')")
                ],
                tier: .t3WorkspaceChanges,
                requiredTCC: [],
                isReversible: true,
                requiresConfirmation: false,
                supportsUndo: true,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "list_directory",
                description: "List files and folders inside an approved directory with optional recursion, limit, and filtering",
                arguments: [
                    ToolArgumentDescriptor(name: "path", description: "Target directory path (e.g. ~/Desktop)", isRequired: true),
                    ToolArgumentDescriptor(name: "recursive", description: "List subdirectories recursively ('true'/'false', default 'false')"),
                    ToolArgumentDescriptor(name: "limit", description: "Maximum number of entries to return (default 50, max 200)"),
                    ToolArgumentDescriptor(name: "filter", description: "Entry type or substring filter ('all', 'folders', 'files', or extension/substring)")
                ],
                tier: .t0Observe,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "rename_file",
                description: "Rename a file or folder within approved directories with collision detection and undo support",
                arguments: [
                    ToolArgumentDescriptor(name: "source", description: "Existing file or directory path", isRequired: true),
                    ToolArgumentDescriptor(name: "destination", description: "New path or new name in same parent directory", isRequired: true),
                    ToolArgumentDescriptor(name: "confirm", description: "Pass 'true' to confirm rename")
                ],
                tier: .t3WorkspaceChanges,
                requiredTCC: [],
                isReversible: true,
                requiresConfirmation: true,
                supportsUndo: true,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "trash_file",
                description: "Safely move a file or folder to macOS Trash (reversible, confirmation required)",
                arguments: [
                    ToolArgumentDescriptor(name: "path", description: "Path of file or directory to move to Trash", isRequired: true),
                    ToolArgumentDescriptor(name: "confirm", description: "Pass 'true' to confirm moving target to Trash")
                ],
                tier: .t3WorkspaceChanges,
                requiredTCC: [],
                isReversible: true,
                requiresConfirmation: true,
                supportsUndo: true,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "search_files",
                description: "Search allowed directories for files matching substring or extension",
                arguments: [
                    ToolArgumentDescriptor(name: "query", description: "Filename substring to search for"),
                    ToolArgumentDescriptor(name: "folder", description: "Folder within allowed directories"),
                    ToolArgumentDescriptor(name: "extension", description: "File extension filter without dot")
                ],
                tier: .t0Observe,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "read_file_safe",
                description: "Safely read up to 64 KB of a file within allowed folders via QuarantinedReader",
                arguments: [
                    ToolArgumentDescriptor(name: "path", description: "Path to file to read", isRequired: true)
                ],
                tier: .t0Observe,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "copy_file",
                description: "Copy a file between allowed folders with undo support",
                arguments: [
                    ToolArgumentDescriptor(name: "source", description: "Source file path", isRequired: true),
                    ToolArgumentDescriptor(name: "destination", description: "Destination file path", isRequired: true)
                ],
                tier: .t1Reversible,
                requiredTCC: [],
                isReversible: true,
                requiresConfirmation: false,
                supportsUndo: true,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "move_file",
                description: "Move a file between allowed folders with undo support (workspace change)",
                arguments: [
                    ToolArgumentDescriptor(name: "source", description: "Source file path", isRequired: true),
                    ToolArgumentDescriptor(name: "destination", description: "Destination file or folder path", isRequired: true),
                    ToolArgumentDescriptor(name: "confirm", description: "Pass 'true' to confirm moving file")
                ],
                tier: .t3WorkspaceChanges,
                requiredTCC: [],
                isReversible: true,
                requiresConfirmation: true,
                supportsUndo: true,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "reminder",
                description: "Create, list, or complete reminders in Pearl/EventKit",
                arguments: [
                    ToolArgumentDescriptor(name: "action", description: "Action: create, list, or complete (default create)", allowedValues: ["create", "list", "complete"]),
                    ToolArgumentDescriptor(name: "title", description: "Reminder title (required for create/complete)"),
                    ToolArgumentDescriptor(name: "id", description: "Reminder ID prefix or UUID (for complete)")
                ],
                tier: .t1Reversible,
                requiredTCC: [.reminders],
                isReversible: true,
                requiresConfirmation: false,
                supportsUndo: true,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "list_windows",
                description: "List visible on-screen application windows with titles, owners, and frames",
                arguments: [],
                tier: .t0Observe,
                requiredTCC: [.accessibility],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "manage_window",
                description: "Manage window position/state (focus, minimize, maximize, tile_left, tile_right)",
                arguments: [
                    ToolArgumentDescriptor(name: "app", description: "Application name", isRequired: true),
                    ToolArgumentDescriptor(name: "action", description: "Action: focus, minimize, maximize, tile_left, tile_right", isRequired: true)
                ],
                tier: .t1Reversible,
                requiredTCC: [.accessibility],
                isReversible: true,
                requiresConfirmation: false,
                supportsUndo: true,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "list_shortcuts",
                description: "List installed user shortcuts from macOS Shortcuts",
                arguments: [],
                tier: .t0Observe,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "run_shortcut",
                description: "Run a user shortcut by name",
                arguments: [
                    ToolArgumentDescriptor(name: "name", description: "Shortcut name", isRequired: true),
                    ToolArgumentDescriptor(name: "input", description: "Optional input text")
                ],
                tier: .t3WorkspaceChanges,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: true,
                supportsUndo: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "list_browser_tabs",
                description: "List open browser tabs from Safari and Chrome",
                arguments: [],
                tier: .t0Observe,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "open_url",
                description: "Open an HTTP or HTTPS URL in the default web browser",
                arguments: [
                    ToolArgumentDescriptor(name: "url", description: "HTTP or HTTPS URL", isRequired: true)
                ],
                tier: .t1Reversible,
                requiredTCC: [],
                isReversible: true,
                requiresConfirmation: false,
                supportsUndo: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "read_active_tab",
                description: "Read the active browser tab title and URL in Safari or Chrome",
                arguments: [],
                tier: .t0Observe,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "create_mail_draft",
                description: "Create an email draft in Apple Mail without sending",
                arguments: [
                    ToolArgumentDescriptor(name: "to", description: "Recipient email", isRequired: true),
                    ToolArgumentDescriptor(name: "subject", description: "Subject", isRequired: true),
                    ToolArgumentDescriptor(name: "body", description: "Message body", isRequired: true)
                ],
                tier: .t2ReadPersonal,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                supportsUndo: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "send_mail",
                description: "Send an email via Apple Mail (T4 External Side Effect, requires explicit confirmation)",
                arguments: [
                    ToolArgumentDescriptor(name: "to", description: "Recipient email", isRequired: true),
                    ToolArgumentDescriptor(name: "subject", description: "Subject", isRequired: true),
                    ToolArgumentDescriptor(name: "body", description: "Message body", isRequired: true)
                ],
                tier: .t4ExternalSideEffects,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: true,
                supportsUndo: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "read_screen_text",
                description: "Read visible text displayed on screen via in-memory OCR",
                arguments: [],
                tier: .t0Observe,
                requiredTCC: [.screenRecording],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            
            // V3.2 Ultron Workflow Edition Tools (Explicitly mcpExposed: false to preserve 8-tool T0-T2 MCP invariant)
            ToolMetadata(
                name: "propose_skill",
                description: "Stage a new or modified Markdown skill or recipe into the ProposalStore review queue",
                arguments: [
                    ToolArgumentDescriptor(name: "name", description: "Target slug name", isRequired: true),
                    ToolArgumentDescriptor(name: "target_kind", description: "skill or recipe", allowedValues: ["skill", "recipe"]),
                    ToolArgumentDescriptor(name: "change_type", description: "create, edit, or delete", allowedValues: ["create", "edit", "delete"]),
                    ToolArgumentDescriptor(name: "title", description: "Proposal title"),
                    ToolArgumentDescriptor(name: "trigger", description: "Trigger phrase"),
                    ToolArgumentDescriptor(name: "description", description: "Description"),
                    ToolArgumentDescriptor(name: "content", description: "Markdown content or numbered steps"),
                    ToolArgumentDescriptor(name: "explanation", description: "Rationale")
                ],
                tier: .t1Reversible,
                requiredTCC: [],
                isReversible: true,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "use_recipe",
                description: "Render a parameterized Markdown recipe or compile one into a skill proposal",
                arguments: [
                    ToolArgumentDescriptor(name: "name", description: "Recipe name or 'list'", isRequired: true),
                    ToolArgumentDescriptor(name: "arguments", description: "JSON object or key=value pairs"),
                    ToolArgumentDescriptor(name: "compile_to_skill", description: "Set true to stage as a skill proposal")
                ],
                tier: .t0Observe,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "search_skill_catalog",
                description: "Search Pearl's built-in 16-blueprint skill catalog and local installed skills",
                arguments: [
                    ToolArgumentDescriptor(name: "query", description: "Keyword filter"),
                    ToolArgumentDescriptor(name: "category", description: "Category filter"),
                    ToolArgumentDescriptor(name: "include_local", description: "Include local skills (default true)")
                ],
                tier: .t0Observe,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "subbot_run",
                description: "Execute a web research sub-bot (search, scrape, crawl, map, monitor)",
                arguments: [
                    ToolArgumentDescriptor(name: "bot_type", description: "Bot type", isRequired: true, allowedValues: ["search", "scrape", "crawl", "map", "monitor"]),
                    ToolArgumentDescriptor(name: "targets", description: "Target URL(s)"),
                    ToolArgumentDescriptor(name: "query", description: "Search query"),
                    ToolArgumentDescriptor(name: "max_depth", description: "Maximum crawl depth"),
                    ToolArgumentDescriptor(name: "limit", description: "Maximum pages/results")
                ],
                tier: .t2ReadPersonal,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "subbot_workflow",
                description: "Execute a composite SubBot research workflow (search_and_scrape, market_research, competitive_analysis)",
                arguments: [
                    ToolArgumentDescriptor(name: "workflow", description: "Workflow name", isRequired: true, allowedValues: ["search_and_scrape", "market_research", "competitive_analysis"]),
                    ToolArgumentDescriptor(name: "query", description: "Search query"),
                    ToolArgumentDescriptor(name: "urls", description: "Comma-separated URLs"),
                    ToolArgumentDescriptor(name: "top_n", description: "Top results to scrape")
                ],
                tier: .t2ReadPersonal,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "vault_list",
                description: "List Markdown notes in the Obsidian-compatible Pearl vault",
                arguments: [],
                tier: .t0Observe,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "vault_read",
                description: "Read a Markdown note from the Pearl vault",
                arguments: [
                    ToolArgumentDescriptor(name: "name", description: "Note name or path", isRequired: true)
                ],
                tier: .t2ReadPersonal,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "vault_write",
                description: "Write or update a Markdown note in the Pearl vault with frontmatter and wikilinks",
                arguments: [
                    ToolArgumentDescriptor(name: "name", description: "Note name or path", isRequired: true),
                    ToolArgumentDescriptor(name: "content", description: "Note body Markdown", isRequired: true),
                    ToolArgumentDescriptor(name: "tags", description: "Comma-separated tags"),
                    ToolArgumentDescriptor(name: "wikilinks", description: "Comma-separated wikilinks")
                ],
                tier: .t1Reversible,
                requiredTCC: [],
                isReversible: true,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "vault_search",
                description: "Search notes in the Obsidian-compatible Pearl vault",
                arguments: [
                    ToolArgumentDescriptor(name: "query", description: "Search query", isRequired: true)
                ],
                tier: .t2ReadPersonal,
                requiredTCC: [],
                isReversible: false,
                requiresConfirmation: false,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            ),
            ToolMetadata(
                name: "write_output_file",
                description: "Atomically write an output artifact (.md, .txt, .csv, .json, .html) to ~/Documents/PearlOutput/",
                arguments: [
                    ToolArgumentDescriptor(name: "filename", description: "Target filename", isRequired: true),
                    ToolArgumentDescriptor(name: "content", description: "File contents", isRequired: true)
                ],
                tier: .t3WorkspaceChanges,
                requiredTCC: [],
                isReversible: true,
                requiresConfirmation: true,
                nativeAssistantExposed: true,
                cliExposed: true,
                mcpExposed: false
            )
        ]
        
        for meta in canonicalList {
            metadataMap[meta.name.lowercased()] = meta
        }
    }
    
    public func registerMetadata(_ metadata: ToolMetadata) {
        lock.lock()
        defer { lock.unlock() }
        metadataMap[metadata.name.lowercased()] = metadata
    }
    
    /// Pre-registers default built-in task execution tools (list_tasks, create_task, complete_task, delete_task).
    public func registerDefaultCoreTools() {
        register(ListTasksTool())
        register(CreateTaskTool())
        register(CompleteTaskTool())
        register(DeleteTaskTool(), metadata: ToolMetadata(
            name: "delete_task",
            description: "Permanently delete a task by ID or title. Requires user confirmation.",
            arguments: [
                ToolArgumentDescriptor(name: "id", type: "string", description: "UUID, 8-character ID prefix, or title of the task to delete", isRequired: true),
                ToolArgumentDescriptor(name: "confirm", type: "string", description: "Pass 'true' to confirm irreversible deletion", isRequired: false)
            ],
            tier: .t2ReadPersonal,
            requiredTCC: [],
            isReversible: false,
            requiresConfirmation: true,
            timeoutSeconds: 15.0,
            supportsUndo: false,
            nativeAssistantExposed: true,
            cliExposed: true,
            mcpExposed: true
        ))
    }
    
    public func register(_ tool: any PearlTool, metadata: ToolMetadata? = nil) {
        lock.lock()
        let key = tool.name.lowercased()
        tools[key] = tool
        let meta = metadata ?? metadataMap[key] ?? ToolMetadata(
            name: tool.name,
            description: tool.description,
            arguments: tool.argumentDescriptors,
            tier: tool.tier,
            requiredTCC: tool.requiredTCC,
            isReversible: tool.isReversible,
            requiresConfirmation: tool.tier >= .t3WorkspaceChanges,
            supportsUndo: tool.isReversible,
            nativeAssistantExposed: true,
            cliExposed: true,
            mcpExposed: tool.tier <= .t2ReadPersonal
        )
        metadataMap[key] = meta
        lock.unlock()
        if isSharedInstance {
            ToolRegistry.shared.register(tool)
        }
    }
    
    /// Registers an array of tools atomically into the catalog (and shared ToolRegistry when on `.shared`).
    public func registerAll(_ tools: [any PearlTool]) {
        for tool in tools {
            register(tool)
        }
    }
    
    /// Returns all sorted registered tool names.
    public func allToolNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return tools.keys.sorted()
    }
    
    /// Returns all canonical metadata entries.
    public func allMetadata() -> [ToolMetadata] {
        lock.lock()
        defer { lock.unlock() }
        return metadataMap.values.sorted { $0.name < $1.name }
    }
    
    public func tool(named name: String) -> (any PearlTool)? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name.lowercased()]
    }
    
    public func metadata(for toolName: String) -> ToolMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return metadataMap[toolName.lowercased()]
    }
    
    public func allTools() -> [any PearlTool] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tools.values).sorted { $0.name < $1.name }
    }
    
    public func exposedTools(for interface: InterfaceType) -> [any PearlTool] {
        lock.lock()
        defer { lock.unlock() }
        return tools.values.filter { tool in
            guard let meta = metadataMap[tool.name.lowercased()] else { return false }
            switch interface {
            case .nativeAssistant: return meta.nativeAssistantExposed
            case .cli: return meta.cliExposed
            case .mcp: return meta.mcpExposed && meta.tier <= .t2ReadPersonal
            }
        }.sorted { $0.name < $1.name }
    }
    
    /// Audits runtime consistency between `CentralToolCatalog` and a `ToolRegistry`.
    public func auditConsistency(against registry: ToolRegistry = .shared) -> ToolConsistencyAuditReport {
        lock.lock()
        let catalogTools = tools
        let metas = metadataMap
        lock.unlock()
        
        let registryTools = Dictionary(uniqueKeysWithValues: registry.allTools().map { ($0.name.lowercased(), $0) })
        let catalogNames = Set(catalogTools.keys)
        let registryNames = Set(registryTools.keys)
        
        let missingFromRegistry = catalogNames.subtracting(registryNames).sorted()
        let missingFromCatalog = registryNames.subtracting(catalogNames).sorted()
        let metadataWithoutImpl = Set(metas.keys).subtracting(catalogNames).sorted()
        
        var tierMismatches: [String] = []
        var descriptorMismatches: [String] = []
        var mcpViolations: [String] = []
        
        for (key, tool) in catalogTools.sorted(by: { $0.key < $1.key }) {
            if let meta = metas[key] {
                if tool.tier != meta.tier {
                    tierMismatches.append("\(tool.name): tool=\(tool.tier), metadata=\(meta.tier)")
                }
                if meta.mcpExposed && (tool.tier > .t2ReadPersonal || meta.tier > .t2ReadPersonal) {
                    mcpViolations.append("\(tool.name): tier \(tool.tier) exposed via MCP")
                }
                if !tool.argumentDescriptors.isEmpty && !meta.arguments.isEmpty {
                    let toolReq = Set(tool.argumentDescriptors.filter(\.isRequired).map(\.name))
                    let metaReq = Set(meta.arguments.filter(\.isRequired).map(\.name))
                    if toolReq != metaReq {
                        descriptorMismatches.append("\(tool.name): tool required=\(toolReq.sorted()), meta required=\(metaReq.sorted())")
                    }
                }
            }
        }
        
        return ToolConsistencyAuditReport(
            catalogCount: catalogNames.count,
            registryCount: registryNames.count,
            missingFromToolRegistry: missingFromRegistry,
            missingFromCatalog: missingFromCatalog,
            metadataWithoutImplementation: metadataWithoutImpl,
            tierMismatches: tierMismatches,
            descriptorMismatches: descriptorMismatches,
            mcpViolations: mcpViolations
        )
    }
    
    public enum InterfaceType: Sendable {
        case nativeAssistant
        case cli
        case mcp
    }
}

/// Runtime diagnostic report comparing tool registration, schemas, tiers, and interface boundaries.
public struct ToolConsistencyAuditReport: Sendable, Codable, Equatable {
    public let catalogCount: Int
    public let registryCount: Int
    public let missingFromToolRegistry: [String]
    public let missingFromCatalog: [String]
    public let metadataWithoutImplementation: [String]
    public let tierMismatches: [String]
    public let descriptorMismatches: [String]
    public let mcpViolations: [String]
    
    public var isHealthy: Bool {
        return catalogCount > 0 &&
            missingFromToolRegistry.isEmpty &&
            missingFromCatalog.isEmpty &&
            metadataWithoutImplementation.isEmpty &&
            tierMismatches.isEmpty &&
            descriptorMismatches.isEmpty &&
            mcpViolations.isEmpty
    }
}
