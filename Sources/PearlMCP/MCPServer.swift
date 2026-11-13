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
    public static let defaultExposedToolNames: Set<String> = [
        "volume",
        "battery",
        "frontmost_app",
        "open_app",
        "close_app",
        "screenshot",
        "reminder",
        "git_status"
    ]
    
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
    
    /// Registers the 8 native T0–T2 tools into the given registry if not already present
    public static func registerDefaultTools(into registry: ToolRegistry = .shared) {
        if registry.tool(named: "volume") == nil { registry.register(VolumeTool()) }
        if registry.tool(named: "battery") == nil { registry.register(BatteryTool()) }
        if registry.tool(named: "frontmost_app") == nil { registry.register(FrontmostAppTool()) }
        if registry.tool(named: "open_app") == nil { registry.register(AppTool()) }
        if registry.tool(named: "close_app") == nil { registry.register(CloseAppTool()) }
        if registry.tool(named: "screenshot") == nil { registry.register(ScreenshotTool()) }
        if registry.tool(named: "reminder") == nil { registry.register(ReminderTool()) }
        if registry.tool(named: "git_status") == nil { registry.register(GitStatusTool()) }
    }
    
    /// Returns the MCP tool schema definition for an exposed tool
    public static func schema(for toolName: String, tool: any PearlTool) -> MCPToolInfo {
        switch toolName.lowercased() {
        case "volume":
            return MCPToolInfo(
                name: tool.name,
                description: tool.description,
                inputSchema: ToolInputSchema(
                    properties: [
                        "level": ToolSchemaProperty(type: "string", description: "Volume level percentage (0-100). Leave empty to query current volume.")
                    ]
                )
            )
        case "battery":
            return MCPToolInfo(
                name: tool.name,
                description: tool.description,
                inputSchema: ToolInputSchema(properties: [:])
            )
        case "frontmost_app":
            return MCPToolInfo(
                name: tool.name,
                description: tool.description,
                inputSchema: ToolInputSchema(properties: [:])
            )
        case "open_app":
            return MCPToolInfo(
                name: tool.name,
                description: tool.description,
                inputSchema: ToolInputSchema(
                    properties: [
                        "app": ToolSchemaProperty(type: "string", description: "Application name or bundle identifier (e.g. 'Safari', 'Xcode')")
                    ],
                    required: ["app"]
                )
            )
        case "close_app":
            return MCPToolInfo(
                name: tool.name,
                description: tool.description,
                inputSchema: ToolInputSchema(
                    properties: [
                        "app": ToolSchemaProperty(type: "string", description: "Application name to quit (e.g. 'Calculator')")
                    ],
                    required: ["app"]
                )
            )
        case "screenshot":
            return MCPToolInfo(
                name: tool.name,
                description: tool.description,
                inputSchema: ToolInputSchema(properties: [:])
            )
        case "reminder":
            return MCPToolInfo(
                name: tool.name,
                description: tool.description,
                inputSchema: ToolInputSchema(
                    properties: [
                        "title": ToolSchemaProperty(type: "string", description: "Title of the reminder to create"),
                        "action": ToolSchemaProperty(type: "string", description: "Action to perform: 'create' (default) or 'list'", enum: ["create", "list"])
                    ]
                )
            )
        case "git_status":
            return MCPToolInfo(
                name: tool.name,
                description: tool.description,
                inputSchema: ToolInputSchema(
                    properties: [
                        "path": ToolSchemaProperty(type: "string", description: "Path to git repository (optional, defaults to current directory)")
                    ]
                )
            )
        default:
            return MCPToolInfo(
                name: tool.name,
                description: tool.description,
                inputSchema: ToolInputSchema(properties: [:])
            )
        }
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
    
    private func handleToolsList(id: JSONValue) -> JSONRPCResponse {
        // Collect all tools in registry that are exposed and <= T2
        let tools = registry.allTools().filter { tool in
            self.exposedToolNames.contains(tool.name.lowercased()) && tool.tier <= .t2ReadPersonal
        }.sorted(by: { $0.name < $1.name })
        
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
        
        // Extract string arguments
        var args: [String: String] = [:]
        if let argObj = paramObj["arguments"]?.objectValue {
            for (k, v) in argObj {
                if let s = v.stringValue {
                    args[k] = s
                }
            }
        }
        
        let lowerName = name.lowercased()
        
        // 1. Check NeverTier & Destructive Tools
        let commandString = ([lowerName] + args.values).joined(separator: " ")
        let neverCheck = NeverTierValidator.validate(command: commandString)
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
        
        // 4. Verify tier policy boundary (T0–T2 only)
        guard tool.tier <= .t2ReadPersonal else {
            await AuditLogger.shared.log(
                tool: name,
                args: args,
                tier: tool.tier,
                trustState: .untrusted,
                success: false
            )
            return JSONRPCResponse(id: id, error: JSONRPCError(
                code: -32002,
                message: "Policy refusal: Tool '\(name)' tier \(tool.tier.rawValue) (T3+) is not exposed over MCP."
            ))
        }
        
        // 5. Execute tool via PolicyEngine with untrusted context
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
