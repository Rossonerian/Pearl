import Foundation
import PearlCore
import PearlMCP
import PearlMemory

signal(SIGPIPE, SIG_IGN)
AssistantPipeline.shared.memoryProvider = PearlMemoryProvider.shared

func sendIPC(command: String, args: [String: String]? = nil) -> (response: IPCResponse?, roundTripMs: Double) {
    let config = PearlConfig.load()
    let socketPath = config.socketPath
    
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        print("Error: Failed to create socket")
        return (nil, 0)
    }
    defer { close(fd) }
    
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        print("Error: Socket path too long")
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
        print("Error: Pearl daemon is not running (cannot connect to \(socketPath))")
        return (nil, 0)
    }
    
    let req = IPCRequest(command: command, arguments: args)
    guard let reqData = try? JSONEncoder().encode(req) else {
        print("Error: Failed to encode request")
        return (nil, 0)
    }
    
    _ = reqData.withUnsafeBytes { write(fd, $0.baseAddress!, reqData.count) }
    
    var buffer = [UInt8](repeating: 0, count: 16384)
    let bytesRead = read(fd, &buffer, buffer.count)
    let end = mach_continuous_time()
    
    var timebaseInfo = mach_timebase_info()
    mach_timebase_info(&timebaseInfo)
    let roundTripMs = Double(end - start) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom) / 1_000_000.0
    
    guard bytesRead > 0 else {
        print("Error: No response from Pearl daemon")
        return (nil, roundTripMs)
    }
    
    let respData = Data(buffer[0..<bytesRead])
    let resp = try? JSONDecoder().decode(IPCResponse.self, from: respData)
    return (resp, roundTripMs)
}

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    print("""
    Pearl CLI (v3.1)
    Usage:
      pearl ping                  Check daemon status & latency
      pearl status                Show resident memory & active state
      pearl mcp                   Launch native MCP server over stdio
      pearl doctor [--security]   Run security audit & integrity checks
      pearl show                  Show floating pill HUD
      pearl hide                  Hide floating pill HUD
      pearl remember <fact>       Explicitly remember a stated fact
      pearl forget <id>           Forget a fact by its identifier
      pearl memory [stats|export] Inspect or export long-term memory
      pearl tasks [list|create|done|delete] Manage local SQLite tasks
      pearl brief                 Generate executive morning briefing
      pearl skills [list|run <name>] Manage or execute user skills/macros
      pearl nudges                Evaluate proactive nudges & quiet hours
      pearl jobs list             Inspect running & scheduled background jobs
      pearl approvals [list|approve <id>|deny <id>] Review pending action approvals
      pearl abort                 Emergency abort all running operations
      pearl quit                  Terminate Pearl daemon
      pearl "<command>"           Send query or command to Pearl
    """)
    exit(0)
}

let cmd = args[0].lowercased()
switch cmd {
case "mcp":
    let server = MCPServer()
    server.runStdioLoop()
    exit(0)
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
                let confirm = args.contains("--confirm") || args.contains("-y")
                let filtered = args.dropFirst(2).filter { $0 != "--confirm" && $0 != "-y" }
                let target = filtered.joined(separator: " ")
                let tool = DeleteTaskTool()
                let res = try await tool.execute(
                    args: ["id": target, "confirm": confirm ? "true" : "false"],
                    context: ToolExecutionContext(userConfirmed: confirm)
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
    let result = sendIPC(command: "jobs", args: ["subcommand": sub])
    if let resp = result.response {
        print(resp.message)
    } else {
        print("Pearl daemon is not running (cannot inspect background jobs).")
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
        print("Pearl daemon is not running (cannot inspect approvals).")
    }
case "abort":
    let result = sendIPC(command: "abort")
    if let resp = result.response {
        print(resp.message)
    } else {
        print("Emergency abort signaled (Pearl daemon offline).")
    }
case "quit":
    let result = sendIPC(command: "quit")
    if let resp = result.response {
        print(resp.message)
    } else {
        exit(1)
    }
default:
    let fullQuery = args.joined(separator: " ")
    let result = sendIPC(command: "execute", args: ["query": fullQuery])
    if let resp = result.response {
        print(resp.message)
    } else {
        exit(1)
    }
}
