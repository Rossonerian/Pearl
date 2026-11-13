import Foundation
import PearlCore
import PearlMemory

signal(SIGPIPE, SIG_IGN)

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
    Pearl CLI (v2.0)
    Usage:
      pearl ping                  Check daemon status & latency
      pearl status                Show resident memory & active state
      pearl doctor [--security]   Run security audit & integrity checks
      pearl show                  Show floating pill HUD
      pearl hide                  Hide floating pill HUD
      pearl remember <fact>       Explicitly remember a stated fact
      pearl forget <id>           Forget a fact by its identifier
      pearl memory [stats|export] Inspect or export long-term memory
      pearl quit                  Terminate Pearl daemon
      pearl "<command>"           Send query or command to Pearl
    """)
    exit(0)
}

let cmd = args[0].lowercased()
switch cmd {
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
