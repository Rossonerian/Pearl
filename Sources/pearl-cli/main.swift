import Foundation
import PearlCore
import PearlMCP
import PearlMemory
import PearlTools

signal(SIGPIPE, SIG_IGN)
AssistantPipeline.shared.memoryProvider = PearlMemoryProvider.shared

func sendIPC(
    command: String,
    args: [String: String]? = nil,
    quietOnOffline: Bool = false
) -> (response: IPCResponse?, roundTripMs: Double) {
    let config = PearlConfig.load()
    let socketPath = config.socketPath
    
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        if !quietOnOffline {
            print("Error: Failed to create socket")
        }
        return (nil, 0)
    }
    defer { close(fd) }
    
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        if !quietOnOffline {
            print("Error: Socket path too long")
        }
        return (nil, 0)
    }
    
    withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
        _ = pathBytes.withUnsafeBufferPointer { buf in
            memcpy(ptr, buf.baseAddress!, buf.count)
        }
    }
    
    let start = mach_continuous_time()
    let connResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    
    guard connResult == 0 else {
        if !quietOnOffline {
            print("Error: Pearl daemon is not running (cannot connect to \(socketPath))")
        }
        return (nil, 0)
    }
    
    let req = IPCRequest(command: command, arguments: args)
    guard let reqData = try? JSONEncoder().encode(req) else {
        if !quietOnOffline {
            print("Error: Failed to encode request")
        }
        return (nil, 0)
    }
    
    _ = reqData.withUnsafeBytes { write(fd, $0.baseAddress!, reqData.count) }
    
    var accumulated = Data()
    var chunk = [UInt8](repeating: 0, count: 16384)
    var decodedResponse: IPCResponse? = nil
    let decoder = JSONDecoder()
    
    while accumulated.count < 2 * 1024 * 1024 {
        let bytesRead = read(fd, &chunk, chunk.count)
        if bytesRead > 0 {
            accumulated.append(contentsOf: chunk[0..<bytesRead])
            if let resp = try? decoder.decode(IPCResponse.self, from: accumulated) {
                decodedResponse = resp
                break
            }
        } else {
            break
        }
    }
    
    let end = mach_continuous_time()
    var timebaseInfo = mach_timebase_info()
    mach_timebase_info(&timebaseInfo)
    let roundTripMs = Double(end - start) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom) / 1_000_000.0
    
    guard let resp = decodedResponse else {
        if !quietOnOffline {
            print("Error: \(accumulated.isEmpty ? "No response" : "Invalid response") from Pearl daemon")
        }
        return (nil, roundTripMs)
    }
    
    return (resp, roundTripMs)
}

func bootstrapLocalToolRuntime() {
    PearlToolsRegistry.registerAll(into: .shared, catalog: .shared)
    MCPServer.registerDefaultTools(into: .shared)
}

func tierDisplayName(_ tier: ToolTier) -> String {
    switch tier {
    case .t0Observe: return "T0 (Observe)"
    case .t1Reversible: return "T1 (Reversible)"
    case .t2ReadPersonal: return "T2 (Read Personal)"
    case .t3WorkspaceChanges: return "T3 (Workspace Changes)"
    case .t4ExternalSideEffects: return "T4 (External Side Effects)"
    case .t5RawShell: return "T5 (Raw Shell)"
    }
}

func isUnhandledIPCCommand(_ response: IPCResponse?) -> Bool {
    guard let resp = response, !resp.success else { return false }
    return resp.message.lowercased().contains("unhandled command")
}

struct CLIToolSummary: Codable {
    let name: String
    let description: String
    let tier: Int
    let tierLabel: String
    let isReversible: Bool
    let requiresConfirmation: Bool
    let supportsUndo: Bool
    let requiredTCC: [String]
    let nativeAssistantExposed: Bool
    let cliExposed: Bool
    let mcpExposed: Bool
    let registeredInCatalog: Bool
    let registeredInRegistry: Bool
}

struct CLIToolsListResponse: Codable {
    let source: String
    let catalogCount: Int
    let registryCount: Int
    let totalCount: Int
    let tools: [CLIToolSummary]
}

struct CLIDaemonToolsListPayload: Codable {
    let catalogCount: Int
    let registryCount: Int
    let totalCount: Int
    let tools: [CLIToolSummary]
}

struct CLIToolInspectResponse: Codable {
    let source: String
    let name: String
    let description: String
    let tier: Int
    let tierLabel: String
    let registeredInCatalog: Bool
    let registeredInRegistry: Bool
    let hasMetadata: Bool
    let isReversible: Bool
    let requiresConfirmation: Bool
    let supportsUndo: Bool
    let timeoutSeconds: Double
    let requiredTCC: [String]
    let nativeAssistantExposed: Bool
    let cliExposed: Bool
    let mcpExposed: Bool
    let arguments: [ToolArgumentDescriptor]
    let mcpSchema: MCPToolInfo?
}

struct CLIDaemonToolInspectPayload: Codable {
    let name: String
    let description: String
    let tier: Int
    let tierLabel: String
    let registeredInCatalog: Bool
    let registeredInRegistry: Bool
    let hasMetadata: Bool
    let isReversible: Bool
    let requiresConfirmation: Bool
    let supportsUndo: Bool
    let timeoutSeconds: Double
    let requiredTCC: [String]
    let nativeAssistantExposed: Bool
    let cliExposed: Bool
    let mcpExposed: Bool
    let arguments: [ToolArgumentDescriptor]
}

struct CLIDaemonSyncSummary: Codable {
    let status: String
    let daemonHealthy: Bool?
    let daemonToolCount: Int?
    let missingFromDaemon: [String]
    let extraInDaemon: [String]
}

struct CLIToolsDoctorResponse: Codable {
    let source: String
    let healthy: Bool
    let catalogCount: Int
    let registryCount: Int
    let missingFromToolRegistry: [String]
    let missingFromCatalog: [String]
    let metadataWithoutImplementation: [String]
    let tierMismatches: [String]
    let descriptorMismatches: [String]
    let mcpViolations: [String]
    let mcpBoundaryIssues: [String]
    let defaultMCPTools: [String]
    let catalogMCPTools: [String]
    let daemonSync: CLIDaemonSyncSummary
}

func printPrettyJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value), let json = String(data: data, encoding: .utf8) {
        print(json)
    }
}

func printUsage() {
    print("""
    Pearl CLI (v\(PearlConfig.currentVersion))
    Usage:
      pearl ask <query> [--confirm|-y]          Send natural-language command or query to Pearl
      pearl "<command>" [--confirm|-y]          Shorthand for `pearl ask "<command>"`
      pearl tools list [--json]                 List live registered tools, tiers, and surface exposure
      pearl tools inspect <name> [--json]       Inspect schema, arguments, TCC, tier, and registration
      pearl tools doctor [--json]               Audit CentralToolCatalog, ToolRegistry, MCP, and daemon sync
      pearl doctor [--security]                 Run security sandbox, storage, catalog, and folder audit
      pearl memory [stats|export]               Inspect or export long-term memory
      pearl tasks [list|create|done|delete]     Manage local SQLite tasks (--confirm/-y on delete)
      pearl mcp-serve | mcp                     Launch native MCP server over stdio (T0-T2 safe tools)
      pearl ping                                Check daemon status & IPC round-trip latency
      pearl status                              Show resident daemon memory & active state
      pearl show | hide | toggle_history        Control floating pill HUD
      pearl remember <fact>                     Explicitly remember a stated fact
      pearl forget <id>                         Forget a fact by its identifier
      pearl brief                               Generate executive morning briefing
      pearl skills [list|run <name>]            Manage or execute user skills/macros
      pearl recipes [list|show <name>|run <name>|delete <name>]  Parameterized Markdown recipes
      pearl review [list|show <id>|approve <id>|reject <id>]     Skill proposal diff queue
      pearl persona [show|executive|ultron|jarvis]               Switch assistant persona
      pearl vault [list|read <name>|write <name> <text>|search <q>]  Obsidian PearlVault notes
      pearl dream                               Synthesize cross-memory links into vault Dreams note
      pearl subbots <search|scrape|crawl|map|monitor> <target>   Parallel web research bots
      pearl cache [stats|clear]                 Inspect or clear TTL cache namespaces
      pearl metrics                             Display p50/p95/p99 latency telemetry
      pearl nudges                              Evaluate proactive nudges & quiet hours
      pearl jobs list                           Inspect running & scheduled background jobs
      pearl approvals [list|approve <id>|deny <id>]              Review pending action approvals
      pearl abort                               Emergency abort all running operations
      pearl quit                                Terminate Pearl daemon
      pearl --help | -h | help                  Show this help message
      pearl --version | -v                      Show Pearl CLI version

    Flags:
      --confirm, -y   Pre-approve T3+ or confirmation-gated actions in non-interactive shells.
                      Without --confirm, interactive terminals prompt: "Confirm execution? [y/N]: "
    """)
}

func handleToolsCommand(subArgs: [String]) -> Int32 {
    let isJSON = subArgs.contains("--json")
    let positional = subArgs.filter { $0 != "--json" }
    let sub = (positional.first ?? "list").lowercased()
    
    if sub == "--help" || sub == "-h" || sub == "help" {
        print("""
        Usage:
          pearl tools list [--json]
          pearl tools inspect <tool_name> [--json]
          pearl tools doctor [--json]
        """)
        return 0
    }
    
    switch sub {
    case "list":
        let ipc = sendIPC(command: "tools", args: ["subcommand": "list"], quietOnOffline: true)
        if let resp = ipc.response, !isUnhandledIPCCommand(resp) {
            let source = "Running Pearl Daemon (IPC)"
            if !resp.success {
                if isJSON {
                    print("{\"source\":\"\(source)\",\"error\":\"\(resp.message.replacingOccurrences(of: "\"", with: "\\\""))\"}")
                } else {
                    print("Source: \(source)\nError: \(resp.message)")
                }
                return 1
            }
            if let rawJSON = resp.data?["json"],
               let data = rawJSON.data(using: .utf8),
               let payload = try? JSONDecoder().decode(CLIDaemonToolsListPayload.self, from: data) {
                let sorted = payload.tools.sorted { $0.name.lowercased() < $1.name.lowercased() }
                if isJSON {
                    printPrettyJSON(CLIToolsListResponse(
                        source: source,
                        catalogCount: payload.catalogCount,
                        registryCount: payload.registryCount,
                        totalCount: sorted.count,
                        tools: sorted
                    ))
                } else {
                    print("Source: \(source)")
                    print("Registered Tools (\(sorted.count); catalog: \(payload.catalogCount), registry: \(payload.registryCount)):")
                    for item in sorted {
                        let rev = item.isReversible ? "reversible" : "irreversible"
                        let conf = item.requiresConfirmation ? "confirm:yes" : "confirm:no"
                        let exposure = "Native:\(item.nativeAssistantExposed ? "yes" : "no") CLI:\(item.cliExposed ? "yes" : "no") MCP:\(item.mcpExposed ? "yes" : "no")"
                        print("  • \(item.name) [\(item.tierLabel)] (\(rev), \(conf)) [\(exposure)] — \(item.description)")
                    }
                }
                return 0
            }
            if isJSON, let rawJSON = resp.data?["json"] {
                print(rawJSON)
            } else {
                print("Source: \(source)\n\(resp.message)")
            }
            return 0
        }
        
        let source = ipc.response == nil
            ? "Local CLI Runtime (Daemon offline)"
            : "Local CLI Runtime (Daemon IPC lacks 'tools' command)"
        bootstrapLocalToolRuntime()
        let catalog = CentralToolCatalog.shared
        let registry = ToolRegistry.shared
        let catalogMap = Dictionary(uniqueKeysWithValues: catalog.allTools().map { ($0.name.lowercased(), $0) })
        let registryMap = Dictionary(uniqueKeysWithValues: registry.allTools().map { ($0.name.lowercased(), $0) })
        let allKeys = Set(catalogMap.keys).union(registryMap.keys)
        
        let summaries: [CLIToolSummary] = allKeys.compactMap { key in
            guard let tool = catalogMap[key] ?? registryMap[key] else { return nil }
            let meta = catalog.metadata(for: key)
            let tier = meta?.tier ?? tool.tier
            let tcc = (meta?.requiredTCC ?? tool.requiredTCC).map(\.rawValue)
            return CLIToolSummary(
                name: tool.name,
                description: meta?.description ?? tool.description,
                tier: tier.rawValue,
                tierLabel: "T\(tier.rawValue)",
                isReversible: meta?.isReversible ?? tool.isReversible,
                requiresConfirmation: meta?.requiresConfirmation ?? (tier >= .t3WorkspaceChanges),
                supportsUndo: meta?.supportsUndo ?? tool.isReversible,
                requiredTCC: tcc,
                nativeAssistantExposed: meta?.nativeAssistantExposed ?? true,
                cliExposed: meta?.cliExposed ?? true,
                mcpExposed: meta?.mcpExposed ?? (tier <= .t2ReadPersonal),
                registeredInCatalog: catalogMap[key] != nil,
                registeredInRegistry: registryMap[key] != nil
            )
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        
        if isJSON {
            printPrettyJSON(CLIToolsListResponse(
                source: source,
                catalogCount: catalogMap.count,
                registryCount: registryMap.count,
                totalCount: summaries.count,
                tools: summaries
            ))
        } else {
            print("Source: \(source)")
            print("Registered Tools (\(summaries.count); catalog: \(catalogMap.count), registry: \(registryMap.count)):")
            for item in summaries {
                let rev = item.isReversible ? "reversible" : "irreversible"
                let conf = item.requiresConfirmation ? "confirm:yes" : "confirm:no"
                let exposure = "Native:\(item.nativeAssistantExposed ? "yes" : "no") CLI:\(item.cliExposed ? "yes" : "no") MCP:\(item.mcpExposed ? "yes" : "no")"
                print("  • \(item.name) [\(item.tierLabel)] (\(rev), \(conf)) [\(exposure)] — \(item.description)")
            }
        }
        return 0
        
    case "inspect":
        let targetName = positional.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetName.isEmpty else {
            print("Usage: pearl tools inspect <tool_name> [--json]")
            return 1
        }
        
        let ipc = sendIPC(command: "tools", args: ["subcommand": "inspect", "name": targetName], quietOnOffline: true)
        if let resp = ipc.response, !isUnhandledIPCCommand(resp) {
            let source = "Running Pearl Daemon (IPC)"
            if let rawJSON = resp.data?["json"],
               let data = rawJSON.data(using: .utf8),
               let payload = try? JSONDecoder().decode(CLIDaemonToolInspectPayload.self, from: data) {
                bootstrapLocalToolRuntime()
                let localTool = CentralToolCatalog.shared.tool(named: payload.name) ?? ToolRegistry.shared.tool(named: payload.name)
                let mcpSchema: MCPToolInfo? = (payload.mcpExposed && payload.tier <= ToolTier.t2ReadPersonal.rawValue)
                    ? localTool.map { MCPServer.schema(for: payload.name, tool: $0) }
                    : nil
                let displayTier = ToolTier(rawValue: payload.tier).map(tierDisplayName) ?? payload.tierLabel
                let full = CLIToolInspectResponse(
                    source: source,
                    name: payload.name,
                    description: payload.description,
                    tier: payload.tier,
                    tierLabel: displayTier,
                    registeredInCatalog: payload.registeredInCatalog,
                    registeredInRegistry: payload.registeredInRegistry,
                    hasMetadata: payload.hasMetadata,
                    isReversible: payload.isReversible,
                    requiresConfirmation: payload.requiresConfirmation,
                    supportsUndo: payload.supportsUndo,
                    timeoutSeconds: payload.timeoutSeconds,
                    requiredTCC: payload.requiredTCC,
                    nativeAssistantExposed: payload.nativeAssistantExposed,
                    cliExposed: payload.cliExposed,
                    mcpExposed: payload.mcpExposed,
                    arguments: payload.arguments,
                    mcpSchema: mcpSchema
                )
                if isJSON {
                    printPrettyJSON(full)
                } else {
                    printToolInspectHuman(full)
                }
                return resp.success ? 0 : 1
            }
            if isJSON, let rawJSON = resp.data?["json"] {
                print(rawJSON)
            } else {
                print("Source: \(source)\n\(resp.message)")
            }
            return resp.success ? 0 : 1
        }
        
        let source = ipc.response == nil
            ? "Local CLI Runtime (Daemon offline)"
            : "Local CLI Runtime (Daemon IPC lacks 'tools' command)"
        bootstrapLocalToolRuntime()
        let catalog = CentralToolCatalog.shared
        let registry = ToolRegistry.shared
        let catalogTool = catalog.tool(named: targetName)
        let registryTool = registry.tool(named: targetName)
        let meta = catalog.metadata(for: targetName)
        
        guard catalogTool != nil || registryTool != nil || meta != nil else {
            if isJSON {
                printPrettyJSON(["source": source, "error": "Tool '\(targetName)' is not registered."])
            } else {
                print("Source: \(source)")
                print("Tool '\(targetName)' is not registered in CentralToolCatalog or ToolRegistry.")
            }
            return 1
        }
        
        let liveTool = catalogTool ?? registryTool
        let resolvedName = liveTool?.name ?? meta?.name ?? targetName
        let resolvedTier = meta?.tier ?? liveTool?.tier ?? .t2ReadPersonal
        let resolvedDesc = meta?.description ?? liveTool?.description ?? ""
        let resolvedArgs: [ToolArgumentDescriptor]
        if let liveArgs = liveTool?.argumentDescriptors, !liveArgs.isEmpty {
            resolvedArgs = liveArgs
        } else if let metaArgs = meta?.arguments, !metaArgs.isEmpty {
            resolvedArgs = metaArgs
        } else {
            resolvedArgs = []
        }
        let resolvedTCC = (meta?.requiredTCC ?? liveTool?.requiredTCC ?? []).map(\.rawValue)
        let mcpExposed = meta?.mcpExposed ?? (resolvedTier <= .t2ReadPersonal)
        let mcpSchema: MCPToolInfo? = (mcpExposed && resolvedTier <= .t2ReadPersonal)
            ? liveTool.map { MCPServer.schema(for: resolvedName, tool: $0) }
            : nil
        
        let inspected = CLIToolInspectResponse(
            source: source,
            name: resolvedName,
            description: resolvedDesc,
            tier: resolvedTier.rawValue,
            tierLabel: tierDisplayName(resolvedTier),
            registeredInCatalog: catalogTool != nil,
            registeredInRegistry: registryTool != nil,
            hasMetadata: meta != nil,
            isReversible: meta?.isReversible ?? liveTool?.isReversible ?? false,
            requiresConfirmation: meta?.requiresConfirmation ?? (resolvedTier >= .t3WorkspaceChanges),
            supportsUndo: meta?.supportsUndo ?? liveTool?.isReversible ?? false,
            timeoutSeconds: meta?.timeoutSeconds ?? 15.0,
            requiredTCC: resolvedTCC,
            nativeAssistantExposed: meta?.nativeAssistantExposed ?? true,
            cliExposed: meta?.cliExposed ?? true,
            mcpExposed: mcpExposed,
            arguments: resolvedArgs,
            mcpSchema: mcpSchema
        )
        
        if isJSON {
            printPrettyJSON(inspected)
        } else {
            printToolInspectHuman(inspected)
        }
        return (catalogTool != nil && registryTool != nil) ? 0 : 1
        
    case "doctor":
        bootstrapLocalToolRuntime()
        let catalog = CentralToolCatalog.shared
        let registry = ToolRegistry.shared
        let report = catalog.auditConsistency(against: registry)
        
        let catalogMCPTools = catalog.exposedTools(for: .mcp).map(\.name).sorted()
        let catalogMCPSet = Set(catalogMCPTools.map { $0.lowercased() })
        let defaultMCPTools = MCPServer.defaultExposedToolNames.sorted()
        
        var mcpBoundaryIssues: [String] = []
        for mcpName in defaultMCPTools {
            if registry.tool(named: mcpName) == nil {
                mcpBoundaryIssues.append("Default MCP tool '\(mcpName)' missing from ToolRegistry")
            }
            if !catalogMCPSet.contains(mcpName.lowercased()) {
                mcpBoundaryIssues.append("Default MCP tool '\(mcpName)' not allowed by CentralToolCatalog.exposedTools(for: .mcp)")
            }
        }
        for tool in catalog.exposedTools(for: .mcp) where tool.tier > .t2ReadPersonal {
            mcpBoundaryIssues.append("Catalog MCP-exposed tool '\(tool.name)' violates T0-T2 boundary (tier \(tool.tier.rawValue))")
        }
        
        let localNames = Set(catalog.allToolNames().map { $0.lowercased() })
        let listIPC = sendIPC(command: "tools", args: ["subcommand": "list"], quietOnOffline: true)
        var daemonSync = CLIDaemonSyncSummary(
            status: "offline (local runtime verified)",
            daemonHealthy: nil,
            daemonToolCount: nil,
            missingFromDaemon: [],
            extraInDaemon: []
        )
        var daemonSyncHealthy = true
        var source = "Local CLI Runtime (Daemon offline)"
        
        if let listResp = listIPC.response {
            if isUnhandledIPCCommand(listResp) {
                source = "Local CLI Runtime (Daemon IPC lacks 'tools' command)"
                daemonSync = CLIDaemonSyncSummary(
                    status: "online (daemon IPC does not implement 'tools')",
                    daemonHealthy: nil,
                    daemonToolCount: nil,
                    missingFromDaemon: [],
                    extraInDaemon: []
                )
            } else {
                source = "Local CLI Runtime + Running Pearl Daemon (IPC)"
                var daemonNames = Set<String>()
                var daemonCount: Int? = nil
                if let rawJSON = listResp.data?["json"],
                   let data = rawJSON.data(using: .utf8),
                   let payload = try? JSONDecoder().decode(CLIDaemonToolsListPayload.self, from: data) {
                    daemonNames = Set(payload.tools.map { $0.name.lowercased() })
                    daemonCount = payload.totalCount
                }
                let missingFromDaemon = daemonNames.isEmpty ? [] : localNames.subtracting(daemonNames).sorted()
                let extraInDaemon = daemonNames.isEmpty ? [] : daemonNames.subtracting(localNames).sorted()
                
                let docIPC = sendIPC(command: "tools", args: ["subcommand": "doctor"], quietOnOffline: true)
                let docHealthy = docIPC.response?.success
                let statusText: String
                if !listResp.success || docHealthy == false {
                    statusText = "online (daemon reported tool doctor issues)"
                    daemonSyncHealthy = false
                } else if !missingFromDaemon.isEmpty || !extraInDaemon.isEmpty {
                    statusText = "online (tool registration mismatch between CLI and daemon)"
                    daemonSyncHealthy = false
                } else {
                    statusText = "online (in sync with local CLI catalog)"
                }
                daemonSync = CLIDaemonSyncSummary(
                    status: statusText,
                    daemonHealthy: docHealthy,
                    daemonToolCount: daemonCount,
                    missingFromDaemon: missingFromDaemon,
                    extraInDaemon: extraInDaemon
                )
            }
        }
        
        let overallHealthy = report.isHealthy && mcpBoundaryIssues.isEmpty && daemonSyncHealthy
        let doctorOutput = CLIToolsDoctorResponse(
            source: source,
            healthy: overallHealthy,
            catalogCount: report.catalogCount,
            registryCount: report.registryCount,
            missingFromToolRegistry: report.missingFromToolRegistry,
            missingFromCatalog: report.missingFromCatalog,
            metadataWithoutImplementation: report.metadataWithoutImplementation,
            tierMismatches: report.tierMismatches,
            descriptorMismatches: report.descriptorMismatches,
            mcpViolations: report.mcpViolations,
            mcpBoundaryIssues: mcpBoundaryIssues,
            defaultMCPTools: defaultMCPTools,
            catalogMCPTools: catalogMCPTools,
            daemonSync: daemonSync
        )
        
        if isJSON {
            printPrettyJSON(doctorOutput)
        } else {
            print("Source: \(source)")
            print("Unified Tool Catalog Doctor: \(overallHealthy ? "HEALTHY" : "UNHEALTHY")")
            print("  Registered Tools: CentralToolCatalog=\(report.catalogCount), ToolRegistry=\(report.registryCount)")
            print("  MCP Surface: default=\(defaultMCPTools.count) tools, catalog MCP-eligible=\(catalogMCPTools.count) tools")
            print("  Daemon Sync: \(daemonSync.status)")
            if !report.missingFromToolRegistry.isEmpty {
                print("  ✗ Missing from ToolRegistry: \(report.missingFromToolRegistry.joined(separator: ", "))")
            }
            if !report.missingFromCatalog.isEmpty {
                print("  ✗ Missing from CentralToolCatalog: \(report.missingFromCatalog.joined(separator: ", "))")
            }
            if !report.metadataWithoutImplementation.isEmpty {
                print("  ✗ Metadata without implementation: \(report.metadataWithoutImplementation.joined(separator: ", "))")
            }
            if !report.tierMismatches.isEmpty {
                print("  ✗ Tier mismatches: \(report.tierMismatches.joined(separator: "; "))")
            }
            if !report.descriptorMismatches.isEmpty {
                print("  ✗ Descriptor mismatches: \(report.descriptorMismatches.joined(separator: "; "))")
            }
            if !report.mcpViolations.isEmpty {
                print("  ✗ Catalog MCP violations: \(report.mcpViolations.joined(separator: "; "))")
            }
            if !mcpBoundaryIssues.isEmpty {
                print("  ✗ MCP boundary issues: \(mcpBoundaryIssues.joined(separator: "; "))")
            }
            if !daemonSync.missingFromDaemon.isEmpty {
                print("  ✗ Missing from running daemon: \(daemonSync.missingFromDaemon.joined(separator: ", "))")
            }
            if !daemonSync.extraInDaemon.isEmpty {
                print("  ✗ Extra on running daemon: \(daemonSync.extraInDaemon.joined(separator: ", "))")
            }
            if overallHealthy {
                print("  ✓ All registered tools, metadata schemas, tiers, and MCP boundaries are consistent.")
            }
        }
        return overallHealthy ? 0 : 1
        
    default:
        print("Unknown tools subcommand '\(sub)'. Available: list, inspect, doctor")
        return 1
    }
}

func printToolInspectHuman(_ item: CLIToolInspectResponse) {
    print("Source: \(item.source)")
    print("Tool: \(item.name)")
    print("Description: \(item.description)")
    print("Tier: \(item.tierLabel)")
    print("Registration: CentralToolCatalog=\(item.registeredInCatalog ? "yes" : "no"), ToolRegistry=\(item.registeredInRegistry ? "yes" : "no"), Metadata=\(item.hasMetadata ? "yes" : "no")")
    print("Policy: reversible=\(item.isReversible), supportsUndo=\(item.supportsUndo), requiresConfirmation=\(item.requiresConfirmation), timeout=\(String(format: "%.1fs", item.timeoutSeconds))")
    print("TCC Services: \(item.requiredTCC.isEmpty ? "none" : item.requiredTCC.joined(separator: ", "))")
    print("Exposure: Native=\(item.nativeAssistantExposed ? "yes" : "no"), CLI=\(item.cliExposed ? "yes" : "no"), MCP=\(item.mcpExposed ? "yes" : "no")")
    if item.arguments.isEmpty {
        print("Arguments: none")
    } else {
        print("Arguments (\(item.arguments.count)):")
        for arg in item.arguments {
            let req = arg.isRequired ? "required" : "optional"
            let allowed = arg.allowedValues.map { " [allowed: \($0.joined(separator: "|"))]" } ?? ""
            print("  • \(arg.name) (\(arg.type), \(req)) — \(arg.description)\(allowed)")
        }
    }
    if let schema = item.mcpSchema {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(schema.inputSchema),
           let schemaStr = String(data: data, encoding: .utf8) {
            print("Live Input Schema (MCP):")
            print(schemaStr)
        }
    } else {
        print("Live Input Schema (MCP): excluded by policy (mcpExposed=\(item.mcpExposed), T\(item.tier))")
    }
}

func requiresInteractiveConfirmation(for response: IPCResponse) -> Bool {
    if response.data?["requiresConfirmation"]?.lowercased() == "true" {
        return true
    }
    if !response.success {
        let lower = response.message.lowercased()
        if lower.contains("requires explicit confirmation") || lower.contains("requires confirmation") || lower.contains("confirmation required") {
            return true
        }
    }
    return false
}

func promptTerminalConfirmation() -> Bool {
    guard isatty(STDIN_FILENO) != 0 else { return false }
    fputs("Confirm execution? [y/N]: ", stdout)
    fflush(stdout)
    guard let line = readLine(strippingNewline: true) else { return false }
    let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized == "y" || normalized == "yes"
}

private final class SendableExitCodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32 = 0
    
    func set(_ newValue: Int32) {
        lock.lock()
        code = newValue
        lock.unlock()
    }
    
    func get() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return code
    }
}

func executeUtteranceCommand(utterance: String, initialConfirmed: Bool) -> Int32 {
    let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        print("Usage: pearl ask <command> [--confirm]")
        return 1
    }
    
    func makeIPCArgs(confirmed: Bool, confirmationArgsJSON: String? = nil) -> [String: String] {
        var payload: [String: String] = [
            "query": trimmed,
            "origin": RequestOrigin.cli.rawValue
        ]
        if confirmed {
            payload["userConfirmed"] = "true"
            payload["confirm"] = "true"
        }
        if let argsJSON = confirmationArgsJSON, !argsJSON.isEmpty {
            payload["freshConfirmationArgsJSON"] = argsJSON
            payload["confirmationArgumentsJSON"] = argsJSON
        }
        return payload
    }
    
    let initialResult = sendIPC(
        command: "execute",
        args: makeIPCArgs(confirmed: initialConfirmed),
        quietOnOffline: true
    )
    
    if let resp = initialResult.response {
        if requiresInteractiveConfirmation(for: resp) && !initialConfirmed {
            if !resp.message.isEmpty {
                print(resp.message)
            }
            if isatty(STDIN_FILENO) != 0 {
                if promptTerminalConfirmation() {
                    let retry = sendIPC(
                        command: "execute",
                        args: makeIPCArgs(
                            confirmed: true,
                            confirmationArgsJSON: resp.data?["confirmationArgumentsJSON"]
                        ),
                        quietOnOffline: false
                    )
                    if let confirmResp = retry.response {
                        print(confirmResp.message)
                        return confirmResp.success ? 0 : 1
                    }
                    return 1
                } else {
                    print("Action cancelled.")
                    return 1
                }
            } else {
                print("Pass --confirm to approve this action.")
                return 1
            }
        }
        
        print(resp.message)
        return resp.success ? 0 : 1
    }
    
    // Daemon offline: execute locally through unified AssistantPipeline + live registered tools.
    bootstrapLocalToolRuntime()
    let exitCodeBox = SendableExitCodeBox()
    let sema = DispatchSemaphore(value: 0)
    Task {
        let firstResponse = await AssistantPipeline.shared.process(
            request: AssistantRequest(
                utterance: trimmed,
                origin: .cli,
                userConfirmed: initialConfirmed
            )
        )
        if firstResponse.requiresConfirmation && !initialConfirmed {
            if !firstResponse.responseText.isEmpty {
                print(firstResponse.responseText)
            }
            if isatty(STDIN_FILENO) != 0 {
                if promptTerminalConfirmation() {
                    let confirmedResponse = await AssistantPipeline.shared.process(
                        request: AssistantRequest(
                            utterance: trimmed,
                            origin: .cli,
                            userConfirmed: true,
                            freshConfirmationArgs: firstResponse.confirmationArguments
                        )
                    )
                    print(confirmedResponse.responseText)
                    exitCodeBox.set(confirmedResponse.success ? 0 : 1)
                } else {
                    print("Action cancelled.")
                    exitCodeBox.set(1)
                }
            } else {
                print("Pass --confirm to approve this action.")
                exitCodeBox.set(1)
            }
        } else {
            print(firstResponse.responseText)
            exitCodeBox.set(firstResponse.success ? 0 : 1)
        }
        sema.signal()
    }
    sema.wait()
    return exitCodeBox.get()
}

let rawArgs = Array(CommandLine.arguments.dropFirst())
let hasConfirmFlag = rawArgs.contains("--confirm") || rawArgs.contains("-y")
let args = rawArgs.filter { $0 != "--confirm" && $0 != "-y" }

guard !args.isEmpty else {
    printUsage()
    exit(0)
}

let cmd = args[0].lowercased()
switch cmd {
case "--help", "-h", "help":
    printUsage()
    exit(0)
case "--version", "-v", "version":
    print("pearl \(PearlConfig.currentVersion)")
    exit(0)
case "mcp", "mcp-serve":
    let server = MCPServer()
    server.runStdioLoop()
    exit(0)
case "tools", "tool":
    let code = handleToolsCommand(subArgs: Array(args.dropFirst()))
    exit(code)
case "doctor":
    let isSecurity = args.contains("--security") || args.count == 1
    let code = DoctorCommand.run(securityOnly: isSecurity)
    exit(code)
case "remember":
    guard args.count > 1 else {
        print("Usage: pearl remember <fact text>")
        exit(1)
    }
    let fact = args.dropFirst().joined(separator: " ")
    let result = sendIPC(command: "remember", args: ["fact": fact])
    if let resp = result.response {
        print(resp.message)
    } else {
        // Direct fallback if daemon is offline
        let sema = DispatchSemaphore(value: 0)
        Task {
            do {
                let store = try MemoryStore()
                let gate = try LearningGate(store: store)
                let (factId, _) = try await gate.explicitRemember(fact: fact, source: "user", trust: .trusted)
                print("Remembered (offline store): '\(fact)' (id: \(factId))")
            } catch {
                print("Error: \(error.localizedDescription)")
            }
            sema.signal()
        }
        sema.wait()
    }
case "forget":
    guard args.count > 1 else {
        print("Usage: pearl forget <id>")
        exit(1)
    }
    let factId = args[1]
    let result = sendIPC(command: "forget", args: ["id": factId])
    if let resp = result.response {
        print(resp.message)
    } else {
        let sema = DispatchSemaphore(value: 0)
        Task {
            do {
                let store = try MemoryStore()
                let gate = try LearningGate(store: store)
                let removed = try await gate.forget(factId: factId)
                if removed {
                    print("Forgot fact \(factId) (offline store)")
                } else {
                    print("Fact \(factId) not found in store")
                }
            } catch {
                print("Error: \(error.localizedDescription)")
            }
            sema.signal()
        }
        sema.wait()
    }
case "memory":
    let sub = args.count > 1 ? args[1].lowercased() : "stats"
    let result = sendIPC(command: "memory", args: ["subcommand": sub])
    if let resp = result.response {
        print(resp.message)
    } else {
        let sema = DispatchSemaphore(value: 0)
        Task {
            do {
                let store = try MemoryStore()
                let gate = try LearningGate(store: store)
                let viewer = MemoryViewer(store: store, gate: gate)
                if sub == "export" {
                    let json = try await viewer.exportJSON()
                    print(json)
                } else {
                    let stats = try await viewer.getStats()
                    print("Memory Stats: \(stats.factCount) facts, \(stats.profileByteCount) profile bytes (\(stats.profileEstimatedTokens) tokens), \(stats.pendingProposalsCount) pending proposals (Schema v\(stats.schemaVersion))")
                }
            } catch {
                print("Error: \(error.localizedDescription)")
            }
            sema.signal()
        }
        sema.wait()
    }
case "brief", "briefing":
    let result = sendIPC(command: "brief")
    if let resp = result.response {
        print(resp.message)
    } else {
        let sema = DispatchSemaphore(value: 0)
        Task {
            do {
                let briefing = try await BriefingEngine.shared.generateMorningBriefing()
                print(briefing)
            } catch {
                print("Error generating briefing: \(error.localizedDescription)")
            }
            sema.signal()
        }
        sema.wait()
    }
case "tasks", "task":
    let sub = args.count > 1 ? args[1].lowercased() : "list"
    let sema = DispatchSemaphore(value: 0)
    Task {
        do {
            switch sub {
            case "list":
                let statusArg = args.count > 2 ? args[2] : "pending"
                let tool = ListTasksTool()
                let res = try await tool.execute(args: ["status": statusArg], context: ToolExecutionContext())
                print(res.message)
            case "create", "add":
                guard args.count > 2 else {
                    print("Usage: pearl tasks create <title> [--priority <low|medium|high|urgent>] [--due <ISO-date>]")
                    sema.signal()
                    return
                }
                var titleWords: [String] = []
                var priority = "medium"
                var due: String? = nil
                var i = 2
                while i < args.count {
                    if args[i] == "--priority" && i + 1 < args.count {
                        priority = args[i + 1]
                        i += 2
                    } else if args[i] == "--due" && i + 1 < args.count {
                        due = args[i + 1]
                        i += 2
                    } else {
                        titleWords.append(args[i])
                        i += 1
                    }
                }
                var toolArgs: [String: String] = [
                    "title": titleWords.joined(separator: " "),
                    "priority": priority
                ]
                if let d = due { toolArgs["due_date"] = d }
                let tool = CreateTaskTool()
                let res = try await tool.execute(args: toolArgs, context: ToolExecutionContext())
                print(res.message)
            case "done", "complete":
                guard args.count > 2 else {
                    print("Usage: pearl tasks done <id or title>")
                    sema.signal()
                    return
                }
                let target = args.dropFirst(2).joined(separator: " ")
                let tool = CompleteTaskTool()
                let res = try await tool.execute(args: ["id": target], context: ToolExecutionContext())
                print(res.message)
            case "delete", "rm":
                guard args.count > 2 else {
                    print("Usage: pearl tasks delete <id or title> [--confirm]")
                    sema.signal()
                    return
                }
                let confirm = hasConfirmFlag || args.contains("--confirm") || args.contains("-y")
                let filtered = args.dropFirst(2).filter { $0 != "--confirm" && $0 != "-y" }
                let target = filtered.joined(separator: " ")
                let tool = DeleteTaskTool()
                let res = try await PolicyEngine.shared.execute(
                    tool: tool,
                    args: ["id": target],
                    context: ToolExecutionContext(
                        trustState: .trusted,
                        userConfirmed: confirm,
                        freshConfirmationArgs: ["id": target],
                        freshConfirmationToolName: tool.name
                    )
                )
                print(res.message)
            default:
                print("Unknown tasks subcommand: '\(sub)'. Available: list, create, done, delete")
            }
        } catch {
            print("Error: \(error.localizedDescription)")
        }
        sema.signal()
    }
    sema.wait()
case "ping":
    let result = sendIPC(command: "ping")
    if let resp = result.response {
        print(String(format: "PONG from Pearl (round-trip: %.2f ms)", result.roundTripMs))
        if let d = resp.data {
            for (k, v) in d {
                print("  \(k): \(v)")
            }
        }
    } else {
        exit(1)
    }
case "status":
    let result = sendIPC(command: "status")
    if let resp = result.response {
        print(resp.message)
        if let d = resp.data {
            for (k, v) in d {
                print("  \(k): \(v)")
            }
        }
    } else {
        exit(1)
    }
case "show":
    let result = sendIPC(command: "show")
    if let resp = result.response {
        print(resp.message)
    } else {
        exit(1)
    }
case "hide":
    let result = sendIPC(command: "hide")
    if let resp = result.response {
        print(resp.message)
    } else {
        exit(1)
    }
case "skills", "skill":
    let sub = args.count > 1 ? args[1].lowercased() : "list"
    let sema = DispatchSemaphore(value: 0)
    Task {
        let engine = SkillEngine.shared
        try? await engine.seedDefaultSkillsIfEmpty()
        
        switch sub {
        case "list":
            let skills = await engine.loadSkills()
            if skills.isEmpty {
                print("No skills found.")
            } else {
                print("Available Skills (\(skills.count)):")
                for s in skills {
                    print("  • \(s.name) - Trigger: \"\(s.trigger)\" (\(s.steps.count) step(s))")
                    print("    \(s.description)")
                }
            }
        case "run":
            guard args.count > 2 else {
                print("Usage: pearl skills run <skill-name>")
                sema.signal()
                return
            }
            let target = args.dropFirst(2).joined(separator: " ")
            let skills = await engine.loadSkills()
            let matched = await engine.matchSkill(for: target)
            if let skill = skills.first(where: { $0.name.lowercased() == target.lowercased() }) ?? matched {
                print("Running skill: \(skill.name) (\(skill.steps.count) steps)")
                for step in skill.steps {
                    print("  [\(step.index)] \(step.description) -> '\(step.utterance)'")
                    let res = sendIPC(command: "execute", args: ["query": step.utterance])
                    if let msg = res.response?.message {
                        print("      \(msg)")
                    }
                }
            } else {
                print("Skill '\(target)' not found.")
            }
        default:
            print("Unknown skills subcommand: '\(sub)'. Available: list, run <name>")
        }
        sema.signal()
    }
    sema.wait()
case "nudges", "nudge":
    let sema = DispatchSemaphore(value: 0)
    Task {
        do {
            let engine = BriefingEngine.shared
            let isQuiet = engine.isQuietHours()
            let nudges = try await engine.evaluateNudges()
            let quietStatus = isQuiet ? " (Quiet Hours Active)" : ""
            if nudges.isEmpty {
                print("No proactive nudges at this time.\(quietStatus)")
            } else {
                print("Proactive Nudges (\(nudges.count))\(quietStatus):")
                for n in nudges {
                    print("  • \(n.priority.badge) [\(n.category.uppercased())] \(n.title): \(n.message)")
                }
            }
        } catch {
            print("Error evaluating nudges: \(error.localizedDescription)")
        }
        sema.signal()
    }
    sema.wait()
case "jobs", "job":
    let sub = args.count > 1 ? args[1].lowercased() : "list"
    var ipcArgs: [String: String] = ["subcommand": sub]
    if (sub == "resume" || sub == "rollback") && args.count > 2 {
        ipcArgs["id"] = args[2]
    }
    let result = sendIPC(command: "jobs", args: ipcArgs)
    if let resp = result.response {
        print(resp.message)
    } else {
        let sema = DispatchSemaphore(value: 0)
        Task {
            do {
                let jobs = try await JobStore.shared.listJobs()
                if jobs.isEmpty {
                    print("No plan jobs recorded.")
                } else {
                    print("Plan Jobs (\(jobs.count)):")
                    for j in jobs.prefix(15) {
                        print("  • [\(j.status.rawValue)] \(j.goal) (\(j.currentStepIndex)/\(j.steps.count)) [ID: \(String(j.id.prefix(8)))]")
                    }
                }
            } catch {
                print("Failed to list jobs: \(error.localizedDescription)")
            }
            sema.signal()
        }
        sema.wait()
    }
case "approvals", "approval":
    let sub = args.count > 1 ? args[1].lowercased() : "list"
    var ipcArgs: [String: String] = ["subcommand": sub]
    if (sub == "approve" || sub == "deny") && args.count > 2 {
        ipcArgs["id"] = args[2]
    }
    let result = sendIPC(command: "approvals", args: ipcArgs)
    if let resp = result.response {
        print(resp.message)
    } else {
        let sema = DispatchSemaphore(value: 0)
        Task {
            let pending = await ApprovalQueue.shared.listPending()
            if pending.isEmpty {
                print("No pending approvals.")
            } else {
                print("Pending Approvals (\(pending.count)):")
                for p in pending {
                    print("  • [\(p.tier)] \(p.toolName) (\(p.reason)) [ID: \(p.id)]")
                }
            }
            sema.signal()
        }
        sema.wait()
    }
case "review":
    let sub = args.count > 1 ? args[1].lowercased() : "list"
    var ipcArgs: [String: String] = ["subcommand": sub]
    if args.count > 2 {
        ipcArgs["id"] = args[2]
    }
    let result = sendIPC(command: "review", args: ipcArgs)
    if let resp = result.response {
        print(resp.message)
        if !resp.success { exit(1) }
    } else {
        do {
            switch sub {
            case "show":
                guard let id = ipcArgs["id"], let p = ProposalStore.shared.getProposal(id: id) else {
                    print("Proposal not found.")
                    exit(1)
                }
                print("Proposal \(p.id) [\(p.status.rawValue)] — \(p.title)\n```diff\n\(p.unifiedDiff())\n```")
            case "approve":
                guard let id = ipcArgs["id"] else { print("Usage: pearl review approve <id>"); exit(1) }
                let approved = try ProposalStore.shared.approveProposal(id: id)
                print("Approved proposal '\(approved.id)' -> \(approved.targetKind.rawValue)/\(approved.targetName).md")
            case "reject":
                guard let id = ipcArgs["id"] else { print("Usage: pearl review reject <id>"); exit(1) }
                let rejected = try ProposalStore.shared.rejectProposal(id: id)
                print("Rejected proposal '\(rejected.id)'.")
            default:
                let pending = ProposalStore.shared.listPending()
                if pending.isEmpty {
                    print("No pending skill/recipe proposals.")
                } else {
                    print("Pending Proposals (\(pending.count)):")
                    for p in pending {
                        print("  • [\(p.changeType.rawValue)] \(p.targetKind.rawValue)/\(p.targetName).md — \(p.title) [ID: \(p.id)]")
                    }
                }
            }
        } catch {
            print("Error: \(error.localizedDescription)")
            exit(1)
        }
    }
case "recipes", "recipe":
    RecipeEngine.shared.ensureSeeded()
    let sub = args.count > 1 ? args[1].lowercased() : "list"
    var ipcArgs: [String: String] = ["subcommand": sub]
    if args.count > 2 {
        ipcArgs["name"] = args[2]
    }
    var kvMap: [String: String] = [:]
    if sub == "run", args.count > 3 {
        for token in args.dropFirst(3) {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                kvMap[parts[0]] = parts[1]
            }
        }
        if let jsonData = try? JSONEncoder().encode(kvMap), let jsonStr = String(data: jsonData, encoding: .utf8) {
            ipcArgs["arguments"] = jsonStr
        }
    }
    let result = sendIPC(command: "recipes", args: ipcArgs)
    if let resp = result.response {
        print(resp.message)
        if !resp.success { exit(1) }
    } else {
        do {
            switch sub {
            case "show":
                guard let name = ipcArgs["name"], let r = RecipeEngine.shared.readRecipe(name: name) else {
                    print("Recipe not found.")
                    exit(1)
                }
                print("Recipe '\(r.name)' — \(r.description)\nInputs: \(r.inputs.joined(separator: ", "))\n\n\(r.body)")
            case "run":
                guard let name = ipcArgs["name"] else { print("Usage: pearl recipes run <name> [key=value...]"); exit(1) }
                let rendered = try RecipeEngine.shared.renderRecipe(name: name, arguments: kvMap)
                print(rendered)
            case "delete":
                guard let name = ipcArgs["name"] else { print("Usage: pearl recipes delete <name>"); exit(1) }
                try RecipeEngine.shared.deleteRecipe(name: name)
                print("Deleted recipe '\(name)'.")
            default:
                let recipes = RecipeEngine.shared.loadRecipes()
                print("Recipes (\(recipes.count)):")
                for r in recipes {
                    print("  • \(r.name) — \(r.description)")
                }
            }
        } catch {
            print("Error: \(error.localizedDescription)")
            exit(1)
        }
    }
case "persona":
    let modeArg: String
    if args.count > 2 && args[1].lowercased() == "set" {
        modeArg = args[2].lowercased()
    } else if args.count > 1 {
        modeArg = args[1].lowercased()
    } else {
        modeArg = "show"
    }
    let result = sendIPC(command: "persona", args: ["mode": modeArg])
    if let resp = result.response {
        print(resp.message)
        if !resp.success { exit(1) }
    } else {
        if modeArg == "show" {
            let mode = PersonaEngine.shared.activeMode
            print("Active persona: \(mode.displayName) (\(mode.rawValue)) — \(mode.description)")
        } else if let mode = PersonaMode(rawValue: modeArg) {
            PersonaEngine.shared.setMode(mode)
            var cfg = PearlConfig.load()
            cfg.activePersona = mode.rawValue
            cfg.save()
            print("Persona switched to \(mode.displayName) — \(mode.description)")
        } else {
            print("Unknown persona '\(modeArg)'. Valid options: executive, ultron, jarvis")
            exit(1)
        }
    }
case "vault":
    let sub = args.count > 1 ? args[1].lowercased() : "list"
    var ipcArgs: [String: String] = ["subcommand": sub]
    if sub == "read", args.count > 2 {
        ipcArgs["name"] = args[2]
    } else if sub == "write", args.count > 3 {
        ipcArgs["name"] = args[2]
        ipcArgs["content"] = args.dropFirst(3).joined(separator: " ")
    } else if sub == "search", args.count > 2 {
        ipcArgs["query"] = args.dropFirst(2).joined(separator: " ")
    }
    let result = sendIPC(command: "vault", args: ipcArgs)
    if let resp = result.response {
        print(resp.message)
        if !resp.success { exit(1) }
    } else {
        do {
            switch sub {
            case "read":
                guard let name = ipcArgs["name"], let body = VaultManager.shared.readNote(name: name) else {
                    print("Vault note not found.")
                    exit(1)
                }
                print(body)
            case "write":
                guard let name = ipcArgs["name"], let content = ipcArgs["content"] else {
                    print("Usage: pearl vault write <name> <text>")
                    exit(1)
                }
                try VaultManager.shared.writeNote(name: name, content: content)
                print("Wrote note '\(name)' to PearlVault.")
            case "search":
                let q = ipcArgs["query"] ?? ""
                let hits = VaultManager.shared.searchNotes(query: q)
                for h in hits {
                    print("  • \(h.file): \(h.snippet)")
                }
            default:
                let notes = VaultManager.shared.listNotes()
                print("PearlVault Notes (\(notes.count)):")
                for n in notes { print("  • \(n)") }
            }
        } catch {
            print("Error: \(error.localizedDescription)")
            exit(1)
        }
    }
case "dream":
    let result = sendIPC(command: "dream")
    if let resp = result.response {
        print(resp.message)
        if !resp.success { exit(1) }
    } else {
        let sema = DispatchSemaphore(value: 0)
        Task {
            do {
                let engine = DreamEngine(vaultManager: .shared, memoryStore: try? MemoryStore())
                let dream = try await engine.synthesizeDream()
                print("Dream Synthesis complete: \(dream.title)\nSaved to: \(dream.savedNotePath)")
            } catch {
                print("Dream synthesis skipped: \(error.localizedDescription)")
            }
            sema.signal()
        }
        sema.wait()
    }
case "subbots", "subbot":
    guard args.count >= 3 else {
        print("Usage: pearl subbots <search|scrape|crawl|map|monitor> <target>")
        exit(1)
    }
    let botTypeRaw = args[1].lowercased()
    let target = args.dropFirst(2).joined(separator: " ")
    let result = sendIPC(command: "subbots", args: ["bot_type": botTypeRaw, "target": target])
    if let resp = result.response {
        print(resp.message)
        if !resp.success { exit(1) }
    } else if let botType = SubBotType(rawValue: botTypeRaw) {
        let sema = DispatchSemaphore(value: 0)
        Task {
            let task = SubBotTask(
                botType: botType,
                targets: botType == .search ? [] : [target],
                query: botType == .search ? target : nil
            )
            let res = await SubBotManager.shared.runBatch([task])
            print(res.first?.markdownContent ?? res.first?.error ?? "SubBot failed.")
            sema.signal()
        }
        sema.wait()
    } else {
        print("Invalid bot type '\(botTypeRaw)'. Choose: search, scrape, crawl, map, monitor")
        exit(1)
    }
case "cache":
    let sub = args.count > 1 ? args[1].lowercased() : "stats"
    let result = sendIPC(command: "cache", args: ["subcommand": sub])
    if let resp = result.response {
        print(resp.message)
    } else {
        if sub == "clear" {
            CacheManager.shared.clearAll()
            print("All Pearl caches cleared.")
        } else {
            print(CacheManager.shared.formattedSummary())
        }
    }
case "metrics":
    let result = sendIPC(command: "metrics")
    if let resp = result.response {
        print(resp.message)
    } else {
        print(PerformanceMonitor.shared.formattedSummary())
    }
case "abort":
    let result = sendIPC(command: "abort")
    if let resp = result.response {
        print(resp.message)
    } else {
        KillSwitch.shared.trigger(reason: "Triggered via CLI abort (offline)")
        print("Emergency abort signaled locally.")
    }
case "toggle_history", "history":
    let result = sendIPC(command: "toggle_history")
    if let resp = result.response {
        print(resp.message)
    } else {
        exit(1)
    }
case "quit":
    let result = sendIPC(command: "quit")
    if let resp = result.response {
        print(resp.message)
    } else {
        exit(1)
    }
case "ask":
    guard args.count > 1 else {
        print("Usage: pearl ask <command> [--confirm|-y]")
        exit(1)
    }
    let askQuery = args.dropFirst().joined(separator: " ")
    exit(executeUtteranceCommand(utterance: askQuery, initialConfirmed: hasConfirmFlag))
default:
    let fullQuery = args.joined(separator: " ")
    exit(executeUtteranceCommand(utterance: fullQuery, initialConfirmed: hasConfirmFlag))
}
