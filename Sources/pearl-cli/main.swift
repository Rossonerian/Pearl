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
    Pearl CLI (v3.2)
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
      pearl recipes [list|show <name>|run <name>|delete <name>] Parameterized recipes
      pearl review [list|show <id>|approve <id>|reject <id>] Skill proposal diff queue
      pearl persona [show|executive|ultron|jarvis] Switch assistant persona
      pearl vault [list|read <name>|write <name> <text>|search <q>] Obsidian PearlVault
      pearl dream                 Synthesize cross-memory links into vault Dreams note
      pearl subbots <search|scrape|crawl|map|monitor> <target> Parallel web research bots
      pearl cache [stats|clear]   Inspect or clear TTL cache namespaces
      pearl metrics               Display p50/p95/p99 latency telemetry
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
case "quit":
    let result = sendIPC(command: "quit")
    if let resp = result.response {
        print(resp.message)
    } else {
        exit(1)
    }
default:
    let queryArgs = (args[0].lowercased() == "ask" && args.count > 1) ? Array(args.dropFirst()) : args
    let fullQuery = queryArgs.joined(separator: " ")
    let result = sendIPC(command: "execute", args: ["query": fullQuery])
    if let resp = result.response {
        print(resp.message)
    } else {
        exit(1)
    }
}
