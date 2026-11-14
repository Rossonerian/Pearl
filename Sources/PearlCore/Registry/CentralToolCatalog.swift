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
    public static let shared = CentralToolCatalog()
    
    private var tools: [String: any PearlTool] = [:]
    private var metadataMap: [String: ToolMetadata] = [:]
    private let lock = NSLock()
    
    public init() {
        registerDefaultCoreTools()
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
        defer { lock.unlock() }
        let key = tool.name.lowercased()
        tools[key] = tool
        let meta = metadata ?? ToolMetadata(
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
        ToolRegistry.shared.register(tool)
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
        return Array(tools.values)
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
        }
    }
    
    public enum InterfaceType: Sendable {
        case nativeAssistant
        case cli
        case mcp
    }
}
