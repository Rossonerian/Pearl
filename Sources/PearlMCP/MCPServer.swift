import Foundation
import PearlCore
import PearlTools

// MARK: - JSON Value Support

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else if let arrVal = try? container.decode([JSONValue].self) {
            self = .array(arrVal)
        } else if let objVal = try? container.decode([String: JSONValue].self) {
            self = .object(objVal)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown JSON value")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
    
    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        default: return nil
        }
    }
    
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .string(let s): return Int(s)
        default: return nil
        }
    }
    
    public var objectValue: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }
    
    public var arrayValue: [JSONValue]? {
        if case .array(let list) = self { return list }
        return nil
    }
}

// MARK: - JSON-RPC 2.0 Structures

public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String?
    public let id: JSONValue?
    public let method: String?
    public let params: JSONValue?
}

public struct JSONRPCError: Codable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?
    
    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONValue?
    public let result: JSONValue?
    public let error: JSONRPCError?
    
    public init(id: JSONValue?, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }
    
    public init(id: JSONValue?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

// MARK: - Tool Schema Structures

public struct ToolSchemaProperty: Codable, Sendable {
    public let type: String
    public let description: String?
    public let `enum`: [String]?
    
    public init(type: String, description: String? = nil, enum: [String]? = nil) {
        self.type = type
        self.description = description
        self.enum = `enum`
    }
}

public struct ToolInputSchema: Codable, Sendable {
    public let type: String
    public let properties: [String: ToolSchemaProperty]
    public let required: [String]?
    
    public init(type: String = "object", properties: [String: ToolSchemaProperty] = [:], required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

public struct MCPToolInfo: Codable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: ToolInputSchema
    
    public init(name: String, description: String, inputSchema: ToolInputSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

// MARK: - Native MCP Server

public final class MCPServer: @unchecked Sendable {
    
    /// Default set of safe T0–T2 tools exposed over MCP
    public static let defaultExposedToolNames: Set<String> = CentralToolCatalog.defaultMCPExposedToolNames
    
    public let exposedToolNames: Set<String>
    public private(set) var isInitialized: Bool = false
    
    private let registry: ToolRegistry
    private let policyEngine: PolicyEngine
    private let lock = NSLock()
    
    private func markInitialized() {
        lock.lock()
        self.isInitialized = true
        lock.unlock()
    }
    
    public init(
        exposedToolNames: Set<String> = MCPServer.defaultExposedToolNames,
        registry: ToolRegistry = .shared,
        policyEngine: PolicyEngine = .shared
    ) {
        self.exposedToolNames = exposedToolNames
        self.registry = registry
        self.policyEngine = policyEngine
        MCPServer.registerDefaultTools(into: registry)
    }
    
    private static func makeDefaultTools() -> [any PearlTool] {
        return [
            VolumeTool(),
            BatteryTool(),
            FrontmostAppTool(),
            AppTool(),
            UndoTool(),
            ScreenshotTool(),
            ReminderTool(),
            GitStatusTool(),
            ListTasksTool(),
            CreateTaskTool(),
            CompleteTaskTool(),
            DeleteTaskTool()
        ]
    }
    
    /// Legacy descriptors for default tools that do not yet override `argumentDescriptors`.
    private static func fallbackLegacyDescriptors(for toolName: String) -> [ToolArgumentDescriptor] {
        switch toolName.lowercased() {
        case "volume":
            return [
                ToolArgumentDescriptor(
                    name: "level",
                    type: "string",
                    description: "Volume level percentage (0-100). Leave empty to query current volume.",
                    isRequired: false
                )
            ]
        case "open_app":
            return [
                ToolArgumentDescriptor(
                    name: "app",
                    type: "string",
                    description: "Application name or bundle identifier (e.g. 'Safari', 'Xcode')",
                    isRequired: true
                )
            ]
        case "git_status":
            return [
                ToolArgumentDescriptor(
                    name: "path",
                    type: "string",
                    description: "Path to git repository (optional, defaults to current directory)",
                    isRequired: false
                )
            ]
        default:
            return []
        }
    }
    
    /// Registers the default T0–T2 tools into the given registry and syncs `CentralToolCatalog.shared`
    /// when registering into `ToolRegistry.shared`.
    public static func registerDefaultTools(into registry: ToolRegistry = .shared) {
        let syncSharedCatalog = (registry === ToolRegistry.shared)
        for tool in makeDefaultTools() {
            if registry.tool(named: tool.name) == nil {
                registry.register(tool)
            }
            guard syncSharedCatalog else { continue }
            
            let lower = tool.name.lowercased()
            let existingMeta = CentralToolCatalog.shared.metadata(for: lower)
            
            if lower == "reminder" {
                let args = !tool.argumentDescriptors.isEmpty
                    ? tool.argumentDescriptors
                    : (existingMeta?.arguments ?? [])
                let tcc = !tool.requiredTCC.isEmpty
                    ? tool.requiredTCC
                    : (existingMeta?.requiredTCC ?? [])
                let syncedMeta = ToolMetadata(
                    name: existingMeta?.name ?? tool.name,
                    description: existingMeta?.description ?? tool.description,
                    arguments: args,
                    tier: tool.tier,
                    requiredTCC: tcc,
                    isReversible: tool.isReversible,
                    requiresConfirmation: existingMeta?.requiresConfirmation ?? (tool.tier >= .t3WorkspaceChanges),
                    timeoutSeconds: existingMeta?.timeoutSeconds ?? 15.0,
                    supportsUndo: existingMeta?.supportsUndo ?? tool.isReversible,
                    nativeAssistantExposed: existingMeta?.nativeAssistantExposed ?? true,
                    cliExposed: existingMeta?.cliExposed ?? true,
                    mcpExposed: true
                )
                CentralToolCatalog.shared.register(tool, metadata: syncedMeta)
            } else if tool.argumentDescriptors.isEmpty,
                      (existingMeta == nil || existingMeta?.arguments.isEmpty == true) {
                let fallback = fallbackLegacyDescriptors(for: lower)
                if !fallback.isEmpty {
                    let syncedMeta = ToolMetadata(
                        name: tool.name,
                        description: existingMeta?.description ?? tool.description,
                        arguments: fallback,
                        tier: tool.tier,
                        requiredTCC: !tool.requiredTCC.isEmpty ? tool.requiredTCC : (existingMeta?.requiredTCC ?? []),
                        isReversible: tool.isReversible,
                        requiresConfirmation: existingMeta?.requiresConfirmation ?? (tool.tier >= .t3WorkspaceChanges),
                        timeoutSeconds: existingMeta?.timeoutSeconds ?? 15.0,
                        supportsUndo: existingMeta?.supportsUndo ?? tool.isReversible,
                        nativeAssistantExposed: existingMeta?.nativeAssistantExposed ?? true,
                        cliExposed: existingMeta?.cliExposed ?? true,
                        mcpExposed: existingMeta?.mcpExposed ?? (tool.tier <= .t2ReadPersonal)
                    )
                    CentralToolCatalog.shared.register(tool, metadata: syncedMeta)
                } else if CentralToolCatalog.shared.tool(named: tool.name) == nil {
                    CentralToolCatalog.shared.register(tool)
                }
            } else if CentralToolCatalog.shared.tool(named: tool.name) == nil {
                CentralToolCatalog.shared.register(tool)
            }
        }
    }
    
    /// Dynamically generates an MCP tool schema from `CentralToolCatalog` / `ToolArgumentDescriptor` metadata.
    public static func schema(for toolName: String, tool: any PearlTool) -> MCPToolInfo {
        let lowerName = toolName.lowercased()
        let catalogMeta = CentralToolCatalog.shared.metadata(for: lowerName)
            ?? CentralToolCatalog.shared.metadata(for: tool.name)
        
        let descriptors: [ToolArgumentDescriptor]
        if !tool.argumentDescriptors.isEmpty {
            descriptors = tool.argumentDescriptors
        } else if let metaArgs = catalogMeta?.arguments, !metaArgs.isEmpty {
            descriptors = metaArgs
        } else {
            descriptors = fallbackLegacyDescriptors(for: lowerName)
        }
        
        var properties: [String: ToolSchemaProperty] = [:]
        var required: [String] = []
        for descriptor in descriptors {
            properties[descriptor.name] = ToolSchemaProperty(
                type: descriptor.type,
                description: descriptor.description,
                enum: descriptor.allowedValues
            )
            if descriptor.isRequired && !required.contains(descriptor.name) {
                required.append(descriptor.name)
            }
        }
        
        return MCPToolInfo(
            name: tool.name,
            description: tool.description,
            inputSchema: ToolInputSchema(
                properties: properties,
                required: required.isEmpty ? nil : required
            )
        )
    }
    
    // MARK: - Message Handling
    
    /// Handles a single JSON-RPC 2.0 message line.
    /// Returns the response string to send back, or nil if the message was a notification.
    public func handleMessage(_ jsonString: String) async -> String? {
        guard let data = jsonString.data(using: .utf8) else {
            return serializeResponse(JSONRPCResponse(id: .null, error: JSONRPCError(code: -32700, message: "Parse error: Unable to read UTF-8 data")))
        }
        
        let decoder = JSONDecoder()
        let request: JSONRPCRequest
        do {
            request = try decoder.decode(JSONRPCRequest.self, from: data)
        } catch {
            return serializeResponse(JSONRPCResponse(id: .null, error: JSONRPCError(code: -32700, message: "Parse error: Invalid JSON payload.")))
        }
        
        // Validate JSON-RPC version
        if let rpc = request.jsonrpc, rpc != "2.0" {
            return serializeResponse(JSONRPCResponse(id: request.id ?? .null, error: JSONRPCError(code: -32600, message: "Invalid Request: 'jsonrpc' must be '2.0'.")))
        }
        
        // Validate method presence
        guard let method = request.method, !method.isEmpty else {
            if request.id != nil {
                return serializeResponse(JSONRPCResponse(id: request.id ?? .null, error: JSONRPCError(code: -32600, message: "Invalid Request: Missing 'method'.")))
            }
            return nil
        }
        
        // Handle notifications (id == nil)
        if request.id == nil {
            if method == "notifications/initialized" {
                markInitialized()
            }
            // Notifications must not produce a response
            return nil
        }
        
        let response = await routeMethod(method: method, id: request.id!, params: request.params)
        return serializeResponse(response)
    }
    
    private func routeMethod(method: String, id: JSONValue, params: JSONValue?) async -> JSONRPCResponse {
        switch method {
        case "initialize":
            return handleInitialize(id: id)
            
        case "ping":
            return JSONRPCResponse(id: id, result: .object([:]))
            
        case "tools/list":
            return handleToolsList(id: id)
            
        case "tools/call":
            return await handleToolsCall(id: id, params: params)
            
        default:
            return JSONRPCResponse(id: id, error: JSONRPCError(code: -32601, message: "Method not found: \(method)"))
        }
    }
    
    private func handleInitialize(id: JSONValue) -> JSONRPCResponse {
        let result: JSONValue = .object([
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([
                "tools": .object([:])
            ]),
            "serverInfo": .object([
                "name": .string("Pearl"),
                "version": .string("2.0.0")
            ])
        ])
        return JSONRPCResponse(id: id, result: result)
    }
    
    private func mcpPermittedTools() -> [any PearlTool] {
        if registry === ToolRegistry.shared {
            let catalogExposedNames = Set(
                CentralToolCatalog.shared.exposedTools(for: .mcp).map { $0.name.lowercased() }
            )
            return registry.allTools().filter { tool in
                let lower = tool.name.lowercased()
                return self.exposedToolNames.contains(lower)
                    && tool.tier <= .t2ReadPersonal
                    && catalogExposedNames.contains(lower)
            }.sorted(by: { $0.name < $1.name })
        }
        return registry.allTools().filter { tool in
            isMCPPolicyPermitted(tool: tool)
        }.sorted(by: { $0.name < $1.name })
    }
    
    private func isMCPPolicyPermitted(tool: any PearlTool) -> Bool {
        let lower = tool.name.lowercased()
        guard self.exposedToolNames.contains(lower), tool.tier <= .t2ReadPersonal else {
            return false
        }
        if registry === ToolRegistry.shared {
            let catalogExposedNames = Set(
                CentralToolCatalog.shared.exposedTools(for: .mcp).map { $0.name.lowercased() }
            )
            return catalogExposedNames.contains(lower)
        }
        if let meta = CentralToolCatalog.shared.metadata(for: lower) {
            let isReminderDefault = (lower == "reminder" && MCPServer.defaultExposedToolNames.contains(lower))
            return (meta.mcpExposed || isReminderDefault) && meta.tier <= .t2ReadPersonal
        }
        return true
    }
    
    private func handleToolsList(id: JSONValue) -> JSONRPCResponse {
        // Collect all tools in registry that pass exposedTools(for: .mcp), exposedToolNames, and T0–T2 bounds
        let tools = mcpPermittedTools()
        
        var toolValues: [JSONValue] = []
        let encoder = JSONEncoder()
        
        for tool in tools {
            let info = MCPServer.schema(for: tool.name, tool: tool)
            if let encodedData = try? encoder.encode(info),
               let jsonVal = try? JSONDecoder().decode(JSONValue.self, from: encodedData) {
                toolValues.append(jsonVal)
            }
        }
        
        let result: JSONValue = .object([
            "tools": .array(toolValues)
        ])
        return JSONRPCResponse(id: id, result: result)
    }
    
    private func handleToolsCall(id: JSONValue, params: JSONValue?) async -> JSONRPCResponse {
        guard let paramObj = params?.objectValue,
              let name = paramObj["name"]?.stringValue, !name.isEmpty else {
            return JSONRPCResponse(id: id, error: JSONRPCError(code: -32602, message: "Invalid params: missing tool name"))
        }
        
        // Extract arguments safely
        var args: [String: String] = [:]
        if let argObj = paramObj["arguments"]?.objectValue {
            for (k, v) in argObj {
                switch v {
                case .string(let s):
                    args[k] = s
                case .int(let i):
                    args[k] = String(i)
                case .double(let d):
                    args[k] = String(d)
                case .bool(let b):
                    args[k] = b ? "true" : "false"
                default:
                    break
                }
            }
        }
        
        let lowerName = name.lowercased()
        
        // 1. Check NeverTier & Destructive Tools
        let sortedArgValues = args.keys.sorted().compactMap { args[$0] }
        let commandString = ([lowerName] + sortedArgValues).joined(separator: " ")
        var neverCheck = NeverTierValidator.validate(command: commandString)
        if !neverCheck.isDenied {
            for val in sortedArgValues {
                let singleCheck = NeverTierValidator.validate(command: val)
                if singleCheck.isDenied {
                    neverCheck = singleCheck
                    break
                }
            }
        }
        let isDestructive = lowerName == "rm" || lowerName == "shell_execute" || lowerName == "git_push_force" ||
                            lowerName.contains("format") || lowerName.contains("wipe")
        
        if neverCheck.isDenied || isDestructive {
            await AuditLogger.shared.log(
                tool: name,
                args: args,
                tier: .t5RawShell,
                trustState: .untrusted,
                success: false
            )
            let reason = neverCheck.reason ?? "Never-Tier destructive action denied by security policy"
            return JSONRPCResponse(id: id, error: JSONRPCError(
                code: -32001,
                message: "Security policy refusal: Tool '\(name)' is blocked by NeverTier policy (\(reason))."
            ))
        }
        
        // 2. Check Exposed List
        guard self.exposedToolNames.contains(lowerName) else {
            await AuditLogger.shared.log(
                tool: name,
                args: args,
                tier: .t5RawShell,
                trustState: .untrusted,
                success: false
            )
            return JSONRPCResponse(id: id, error: JSONRPCError(
                code: -32002,
                message: "Tool '\(name)' is not exposed over MCP (policy: T0-T2 safe tools only)."
            ))
        }
        
        // 3. Look up registered tool
        guard let tool = registry.tool(named: name) else {
            await AuditLogger.shared.log(
                tool: name,
                args: args,
                tier: .t5RawShell,
                trustState: .untrusted,
                success: false
            )
            return JSONRPCResponse(id: id, error: JSONRPCError(
                code: -32601,
                message: "Tool '\(name)' not found in ToolRegistry."
            ))
        }
        
        // 4. Verify tier & catalog MCP policy boundary (T0–T2 and exposedTools(for: .mcp) only)
        guard isMCPPolicyPermitted(tool: tool) else {
            await AuditLogger.shared.log(
                tool: name,
                args: args,
                tier: tool.tier,
                trustState: .untrusted,
                success: false
            )
            let message = tool.tier > .t2ReadPersonal
                ? "Policy refusal: Tool '\(name)' tier \(tool.tier.rawValue) (T3+) is not exposed over MCP."
                : "Policy refusal: Tool '\(name)' is excluded from MCP exposure by catalog policy."
            return JSONRPCResponse(id: id, error: JSONRPCError(
                code: -32002,
                message: message
            ))
        }
        
        // 5. Validate required tool arguments
        for descriptor in tool.argumentDescriptors where descriptor.isRequired {
            guard let val = args[descriptor.name]?.trimmingCharacters(in: .whitespacesAndNewlines), !val.isEmpty else {
                return JSONRPCResponse(id: id, error: JSONRPCError(
                    code: -32602,
                    message: "Invalid params: missing required argument '\(descriptor.name)' for tool '\(name)'"
                ))
            }
        }
        
        // 6. Execute tool via PolicyEngine with untrusted context
        let context = ToolExecutionContext(trustState: .untrusted, userConfirmed: false, providerIsLocal: true)
        do {
            let result = try await policyEngine.execute(tool: tool, args: args, context: context)
            let responseResult: JSONValue = .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(result.message)
                    ])
                ]),
                "isError": .bool(!result.success)
            ])
            return JSONRPCResponse(id: id, result: responseResult)
        } catch {
            await AuditLogger.shared.log(
                tool: name,
                args: args,
                tier: tool.tier,
                trustState: .untrusted,
                success: false
            )
            return JSONRPCResponse(id: id, error: JSONRPCError(
                code: -32000,
                message: "Tool execution error: \(error.localizedDescription)"
            ))
        }
    }
    
    private func serializeResponse(_ response: JSONRPCResponse) -> String {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(response),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Internal serialization error\"}}"
    }
    
    // MARK: - Stdio Loop
    
    /// Synchronous runner for pearl-cli mcp
    public func runStdioLoop() {
        let sema = DispatchSemaphore(value: 0)
        Task {
            await self.runStdioLoopAsync()
            sema.signal()
        }
        sema.wait()
    }
    
    /// Async runner processing standard input until EOF
    public func runStdioLoopAsync() async {
        // Read line by line from stdin
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            if let responseStr = await handleMessage(trimmed) {
                if let outData = (responseStr + "\n").data(using: .utf8) {
                    FileHandle.standardOutput.write(outData)
                    fflush(stdout)
                }
            }
        }
        // Clean shutdown on stdin EOF
    }
    
    /// Loop for custom file handles (useful for pipes & automated tests)
    public func runLoop(input: FileHandle, output: FileHandle) async {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break } // EOF
            buffer.append(chunk)
            
            while let newlineRange = buffer.range(of: Data([0x0A])) { // \n
                let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
                buffer.removeSubrange(0..<newlineRange.upperBound)
                
                if let lineStr = String(data: lineData, encoding: .utf8) {
                    let trimmed = lineStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        if let responseStr = await handleMessage(trimmed) {
                            if let outData = (responseStr + "\n").data(using: .utf8) {
                                output.write(outData)
                            }
                        }
                    }
                }
            }
        }
    }
}
