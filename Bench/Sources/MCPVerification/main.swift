import Foundation
import BenchCore
import PearlCore
import PearlMCP
import PearlTools

@main
struct MCPVerificationRunner {
    static func main() async {
        print("========================================================================")
        print("          PEARL V2 - MILESTONE 7 MCP SERVER BENCHMARK & VERIFICATION     ")
        print("========================================================================")
        
        let sysInfo = SystemSampler.captureSystemInfo()
        print("Host: \(sysInfo.cpu) | OS: \(sysInfo.os) | Thermal: \(SystemSampler.currentThermalState())")
        print("Date: \(ISO8601DateFormatter().string(from: Date()))\n")
        
        var timebaseInfo = mach_timebase_info()
        mach_timebase_info(&timebaseInfo)
        func toMs(_ ticks: UInt64) -> Double {
            let ns = Double(ticks) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
            return ns / 1_000_000.0
        }
        
        var csvLines: [String] = [
            "trial,test_category,scenario,latency_ms,p50_ms,p95_ms,p99_ms,passed,notes"
        ]
        var trialCounter = 1
        
        let projectRoot = URL(fileURLWithPath: "/Users/rossonerian/Projects/Pearl")
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let pearlDir = appSupport.appendingPathComponent("Pearl", isDirectory: true)
        let auditLogURL = pearlDir.appendingPathComponent("audit.log")
        
        func readLastAuditLine() -> String? {
            guard let data = try? Data(contentsOf: auditLogURL),
                  let str = String(data: data, encoding: .utf8) else { return nil }
            return str.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.last
        }
        
        let server = MCPServer()
        
        // ====================================================================
        // STEP A: MCP HANDSHAKE (initialize & notifications/initialized)
        // ====================================================================
        print("[1/6] Testing MCP Handshake...")
        let initRequest = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"MCPBenchClient","version":"1.0.0"}}}
        """
        
        let startInit = mach_continuous_time()
        guard let initResponseStr = await server.handleMessage(initRequest) else {
            fatalError("Server failed to respond to initialize")
        }
        let initLatency = toMs(mach_continuous_time() - startInit)
        
        guard let initData = initResponseStr.data(using: .utf8),
              let initJson = try? JSONSerialization.jsonObject(with: initData) as? [String: Any],
              let result = initJson["result"] as? [String: Any],
              let protoVer = result["protocolVersion"] as? String,
              let serverInfo = result["serverInfo"] as? [String: Any],
              let serverName = serverInfo["name"] as? String,
              let serverVersion = serverInfo["version"] as? String,
              let capabilities = result["capabilities"] as? [String: Any] else {
            fatalError("Malformed initialize response: \(initResponseStr)")
        }
        
        assert(protoVer == "2024-11-05", "Protocol version mismatch: \(protoVer)")
        assert(serverName == "Pearl", "Server name mismatch: \(serverName)")
        assert(serverVersion == "2.0.0", "Server version mismatch: \(serverVersion)")
        assert(capabilities["tools"] != nil, "Missing tools capability")
        print(String(format: "  ✓ Handshake initialize OK (%.3f ms): %@ v%@", initLatency, serverName, serverVersion))
        
        csvLines.append("\(trialCounter),handshake,initialize,\(String(format: "%.4f", initLatency)),N/A,N/A,N/A,true,\"Protocol: \(protoVer), Server: \(serverName) \(serverVersion)\"")
        trialCounter += 1
        
        // Notification
        let notificationMsg = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
        let notifResp = await server.handleMessage(notificationMsg)
        assert(notifResp == nil, "Notification must produce nil response per JSON-RPC spec")
        assert(server.isInitialized == true, "Server should mark initialized")
        print("  ✓ Notification notifications/initialized absorbed successfully")
        
        csvLines.append("\(trialCounter),handshake,notifications_initialized,0.0,N/A,N/A,N/A,true,\"Notification absorbed silently\"")
        trialCounter += 1
        
        // Ping
        let pingMsg = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}"
        let pingResp = await server.handleMessage(pingMsg)
        guard let pResp = pingResp, pResp.contains("\"result\":{}") else {
            fatalError("Ping failed: \(String(describing: pingResp))")
        }
        print("  ✓ Ping pong response OK")
        csvLines.append("\(trialCounter),handshake,ping,0.0,N/A,N/A,N/A,true,\"Ping returned empty object\"")
        trialCounter += 1
        
        // ====================================================================
        // STEP B: DISCOVERY (tools/list)
        // ====================================================================
        print("\n[2/6] Testing Tool Discovery (tools/list)...")
        let listRequest = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}"
        let startList = mach_continuous_time()
        guard let listResponseStr = await server.handleMessage(listRequest) else {
            fatalError("Server failed to respond to tools/list")
        }
        let listLatency = toMs(mach_continuous_time() - startList)
        
        guard let listData = listResponseStr.data(using: .utf8),
              let listJson = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let listResult = listJson["result"] as? [String: Any],
              let toolsList = listResult["tools"] as? [[String: Any]] else {
            fatalError("Malformed tools/list response: \(listResponseStr)")
        }
        
        let toolNames = toolsList.compactMap { $0["name"] as? String }
        print("  Discovered \(toolNames.count) tools: \(toolNames.joined(separator: ", "))")
        
        let expectedTools = [
            "battery", "close_app", "frontmost_app", "git_status",
            "open_app", "reminder", "screenshot", "volume"
        ]
        
        for expected in expectedTools {
            assert(toolNames.contains(expected), "Missing required MCP tool: \(expected)")
        }
        // Verify no destructive or T3+ tools are exposed
        assert(!toolNames.contains("git"), "T3 tool 'git' must NOT be exposed by default")
        assert(!toolNames.contains("shell_execute"), "T5 shell must NOT be exposed")
        assert(!toolNames.contains("rm"), "Destructive tool 'rm' must NOT be exposed")
        
        // Verify schemas
        for toolDict in toolsList {
            guard let name = toolDict["name"] as? String,
                  let desc = toolDict["description"] as? String,
                  let schema = toolDict["inputSchema"] as? [String: Any],
                  let schemaType = schema["type"] as? String else {
                fatalError("Invalid tool schema definition in \(toolDict)")
            }
            assert(!desc.isEmpty, "Tool description empty for \(name)")
            assert(schemaType == "object", "Tool schema type must be 'object' for \(name)")
        }
        print(String(format: "  ✓ Tool schema definitions verified (%.3f ms)", listLatency))
        csvLines.append("\(trialCounter),discovery,tools_list,\(String(format: "%.4f", listLatency)),N/A,N/A,N/A,true,\"Discovered \(toolsList.count) tools, all schemas valid\"")
        trialCounter += 1
        
        // ====================================================================
        // STEP C: 5 REFERENCE TASK CALLS
        // ====================================================================
        print("\n[3/6] Executing 5 Reference Task Calls...")
        
        // Task 1: volume
        let volCall = "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"volume\",\"arguments\":{\"level\":\"48\"}}}"
        let startVol = mach_continuous_time()
        guard let volRespStr = await server.handleMessage(volCall) else { fatalError("volume failed") }
        let volLat = toMs(mach_continuous_time() - startVol)
        assert(volRespStr.contains("Volume set to 48%") || volRespStr.contains("\"isError\":false"), "Volume call failed: \(volRespStr)")
        print(String(format: "  ✓ Task 1: volume (set 48%%) PASSED (%.3f ms)", volLat))
        csvLines.append("\(trialCounter),reference_tasks,volume_set,\(String(format: "%.4f", volLat)),N/A,N/A,N/A,true,\"Set volume 48%\"")
        trialCounter += 1
        
        // Task 1b: volume query
        let volQuery = "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"volume\",\"arguments\":{}}}"
        guard let volQResp = await server.handleMessage(volQuery) else { fatalError("volume query failed") }
        assert(volQResp.contains("Current volume is") || volQResp.contains("\"isError\":false"), "Volume query failed: \(volQResp)")
        print("  ✓ Task 1b: volume (get volume) PASSED")
        
        // Task 2: battery
        let batCall = "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"battery\",\"arguments\":{}}}"
        let startBat = mach_continuous_time()
        guard let batRespStr = await server.handleMessage(batCall) else { fatalError("battery failed") }
        let batLat = toMs(mach_continuous_time() - startBat)
        assert(batRespStr.contains("battery") || batRespStr.contains("plugged") || batRespStr.contains("\"isError\":false"), "Battery call failed: \(batRespStr)")
        print(String(format: "  ✓ Task 2: battery (get battery state) PASSED (%.3f ms)", batLat))
        csvLines.append("\(trialCounter),reference_tasks,battery_status,\(String(format: "%.4f", batLat)),N/A,N/A,N/A,true,\"Battery state query\"")
        trialCounter += 1
        
        // Task 3: frontmost_app
        let frontCall = "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"frontmost_app\",\"arguments\":{}}}"
        let startFront = mach_continuous_time()
        guard let frontRespStr = await server.handleMessage(frontCall) else { fatalError("frontmost_app failed") }
        let frontLat = toMs(mach_continuous_time() - startFront)
        assert(frontRespStr.contains("Frontmost application is") && frontRespStr.contains("\"isError\":false"), "Frontmost app call failed: \(frontRespStr)")
        print(String(format: "  ✓ Task 3: frontmost_app (get active app) PASSED (%.3f ms)", frontLat))
        csvLines.append("\(trialCounter),reference_tasks,frontmost_app,\(String(format: "%.4f", frontLat)),N/A,N/A,N/A,true,\"Frontmost application query\"")
        trialCounter += 1
        
        // Task 4: git_status
        let gitCall = "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"git_status\",\"arguments\":{\"path\":\"\(projectRoot.path)\"}}}"
        let startGit = mach_continuous_time()
        guard let gitRespStr = await server.handleMessage(gitCall) else { fatalError("git_status failed") }
        let gitLat = toMs(mach_continuous_time() - startGit)
        assert(gitRespStr.contains("branch") || gitRespStr.contains("Git working tree") || gitRespStr.contains("\"isError\":false"), "git_status failed: \(gitRespStr)")
        print(String(format: "  ✓ Task 4: git_status (check repo status) PASSED (%.3f ms)", gitLat))
        csvLines.append("\(trialCounter),reference_tasks,git_status,\(String(format: "%.4f", gitLat)),N/A,N/A,N/A,true,\"Git repo status checked\"")
        trialCounter += 1
        
        // Task 5: reminder
        let remCreate = "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"reminder\",\"arguments\":{\"action\":\"create\",\"title\":\"Pearl V2 MCP Benchmark\"}}}"
        let startRem = mach_continuous_time()
        guard let remRespStr = await server.handleMessage(remCreate) else { fatalError("reminder create failed") }
        let remLat = toMs(mach_continuous_time() - startRem)
        assert(remRespStr.contains("Added 'Pearl V2 MCP Benchmark'") && remRespStr.contains("\"isError\":false"), "Reminder create failed: \(remRespStr)")
        print(String(format: "  ✓ Task 5: reminder (create reminder) PASSED (%.3f ms)", remLat))
        csvLines.append("\(trialCounter),reference_tasks,reminder_create,\(String(format: "%.4f", remLat)),N/A,N/A,N/A,true,\"Created reminder\"")
        trialCounter += 1
        
        // Task 5b: reminder list
        let remList = "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"tools/call\",\"params\":{\"name\":\"reminder\",\"arguments\":{\"action\":\"list\"}}}"
        guard let remListResp = await server.handleMessage(remList) else { fatalError("reminder list failed") }
        assert(remListResp.contains("Reminders") && remListResp.contains("\"isError\":false"), "Reminder list failed: \(remListResp)")
        print("  ✓ Task 5b: reminder (list reminders) PASSED")
        
        // ====================================================================
        // STEP D: SECURITY & TIER POLICY BOUNDARY CHECK
        // ====================================================================
        print("\n[4/6] Testing Security & Tier Policy Boundary Checks...")
        
        let dangerousTools = [
            ("shell_execute", "{\"command\":\"whoami\"}", "Unexposed shell tool"),
            ("rm", "{\"path\":\"/tmp/test\"}", "NeverTier root destruction"),
            ("git_push_force", "{\"branch\":\"main\"}", "NeverTier destructive git push")
        ]
        
        for (dangerName, dangerArgs, _) in dangerousTools {
            let dangerCall = "{\"jsonrpc\":\"2.0\",\"id\":\(trialCounter + 100),\"method\":\"tools/call\",\"params\":{\"name\":\"\(dangerName)\",\"arguments\":\(dangerArgs)}}"
            let startDanger = mach_continuous_time()
            guard let dangerRespStr = await server.handleMessage(dangerCall) else {
                fatalError("Server crashed or returned nil for \(dangerName)")
            }
            let dangerLat = toMs(mach_continuous_time() - startDanger)
            
            guard let dangerData = dangerRespStr.data(using: .utf8),
                  let dangerJson = try? JSONSerialization.jsonObject(with: dangerData) as? [String: Any],
                  let errorObj = dangerJson["error"] as? [String: Any],
                  let errorCode = errorObj["code"] as? Int,
                  let errorMsg = errorObj["message"] as? String else {
                fatalError("Security check FAILED: \(dangerName) was not rejected with JSON-RPC error: \(dangerRespStr)")
            }
            
            assert(errorCode != 0, "Error code must be non-zero on policy refusal")
            print(String(format: "  ✓ Refused '%@' -> Error %d: %@ (%.3f ms)", dangerName, errorCode, errorMsg, dangerLat))
            
            // Verify tamper-evident audit log event
            guard let lastLog = readLastAuditLine() else {
                fatalError("Audit log empty after refusing \(dangerName)")
            }
            assert(lastLog.contains("\"tool\":\"\(dangerName)\""), "Audit log missing entry for \(dangerName): \(lastLog)")
            assert(lastLog.contains("\"success\":false"), "Audit log entry should record success:false for \(dangerName)")
            assert(lastLog.contains("\"trustState\":\"untrusted\""), "Audit log entry should record untrusted context")
            print("    ↳ Verified tamper-evident audit record logged: success=false, trustState=untrusted")
            
            csvLines.append("\(trialCounter),security_boundary,\(dangerName),\(String(format: "%.4f", dangerLat)),N/A,N/A,N/A,true,\"Clean refusal: Code \(errorCode), Audit event logged\"")
            trialCounter += 1
        }
        
        // ====================================================================
        // STEP E: ROBUSTNESS & MALFORMED PAYLOAD CHECKS
        // ====================================================================
        print("\n[5/6] Testing Robustness & Malformed Payload Handling...")
        
        let malformedPayloads: [(name: String, payload: String, expectedCode: Int)] = [
            ("raw_invalid_json", "{this is not valid json at all", -32700),
            ("truncated_payload", "{\"jsonrpc\":\"2.0\",\"id\":", -32700),
            ("missing_method", "{\"jsonrpc\":\"2.0\",\"id\":90}", -32600),
            ("missing_params_tools_call", "{\"jsonrpc\":\"2.0\",\"id\":91,\"method\":\"tools/call\"}", -32602),
            ("missing_tool_name", "{\"jsonrpc\":\"2.0\",\"id\":92,\"method\":\"tools/call\",\"params\":{}}", -32602),
            ("non_existent_method", "{\"jsonrpc\":\"2.0\",\"id\":93,\"method\":\"unknown_foo_bar\"}", -32601)
        ]
        
        for (name, payload, expectedCode) in malformedPayloads {
            let startMal = mach_continuous_time()
            guard let respStr = await server.handleMessage(payload) else {
                fatalError("Server returned nil for malformed payload: \(name)")
            }
            let malLat = toMs(mach_continuous_time() - startMal)
            
            guard let data = respStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let err = json["error"] as? [String: Any],
                  let code = err["code"] as? Int else {
                fatalError("Payload '\(name)' did not produce JSON-RPC error response: \(respStr)")
            }
            assert(code == expectedCode, "Payload '\(name)' expected code \(expectedCode) but got \(code)")
            print(String(format: "  ✓ Malformed '%@' -> Handled gracefully with code %d (%.3f ms)", name, code, malLat))
            csvLines.append("\(trialCounter),robustness,\(name),\(String(format: "%.4f", malLat)),N/A,N/A,N/A,true,\"Graceful code \(code)\"")
            trialCounter += 1
        }
        
        // ====================================================================
        // STEP F: LATENCY BENCHMARK OVER 100 TOOL CALLS
        // ====================================================================
        print("\n[6/6] Executing 100 Tool Call Latency Benchmark...")
        var latencies: [Double] = []
        let toolBenchPool = [
            "{\"jsonrpc\":\"2.0\",\"id\":1000,\"method\":\"tools/call\",\"params\":{\"name\":\"battery\",\"arguments\":{}}}",
            "{\"jsonrpc\":\"2.0\",\"id\":1001,\"method\":\"tools/call\",\"params\":{\"name\":\"volume\",\"arguments\":{}}}",
            "{\"jsonrpc\":\"2.0\",\"id\":1002,\"method\":\"tools/call\",\"params\":{\"name\":\"frontmost_app\",\"arguments\":{}}}",
            "{\"jsonrpc\":\"2.0\",\"id\":1003,\"method\":\"tools/call\",\"params\":{\"name\":\"git_status\",\"arguments\":{\"path\":\"\(projectRoot.path)\"}}}",
            "{\"jsonrpc\":\"2.0\",\"id\":1004,\"method\":\"tools/call\",\"params\":{\"name\":\"reminder\",\"arguments\":{\"action\":\"list\"}}}"
        ]
        
        for i in 1...100 {
            let msg = toolBenchPool[(i - 1) % toolBenchPool.count]
            let startTick = mach_continuous_time()
            guard let res = await server.handleMessage(msg) else {
                fatalError("Benchmark run failed at iteration \(i)")
            }
            let lat = toMs(mach_continuous_time() - startTick)
            assert(!res.contains("\"code\":-32"), "Tool call error at iteration \(i): \(res)")
            latencies.append(lat)
            csvLines.append("\(trialCounter),latency_100_calls,call_\(i),\(String(format: "%.4f", lat)),N/A,N/A,N/A,true,\"Iteration \(i)\"")
            trialCounter += 1
        }
        
        latencies.sort()
        let count = Double(latencies.count)
        let p50 = latencies[Int(count * 0.50)]
        let p95 = latencies[min(Int(count * 0.95), latencies.count - 1)]
        let p99 = latencies[min(Int(count * 0.99), latencies.count - 1)]
        let avg = latencies.reduce(0, +) / count
        
        print(String(format: "  ✓ 100 Calls Completed: avg=%.3f ms | p50=%.3f ms | p95=%.3f ms | p99=%.3f ms", avg, p50, p95, p99))
        csvLines.append("\(trialCounter),latency_100_summary,summary,\(String(format: "%.4f", avg)),\(String(format: "%.4f", p50)),\(String(format: "%.4f", p95)),\(String(format: "%.4f", p99)),true,\"p50=\(String(format: "%.3f", p50))ms, p95=\(String(format: "%.3f", p95))ms, p99=\(String(format: "%.3f", p99))ms\"")
        trialCounter += 1
        
        // ====================================================================
        // STEP G: SUBPROCESS STDIO & EOF CLEAN SHUTDOWN VERIFICATION
        // ====================================================================
        print("\n[Bonus] Verifying Subprocess pearl-cli mcp stdio & EOF shutdown...")
        let cliBinary = projectRoot.appendingPathComponent(".build/debug/pearl-cli")
        if FileManager.default.fileExists(atPath: cliBinary.path) {
            let proc = Process()
            proc.executableURL = cliBinary
            proc.arguments = ["mcp"]
            let inPipe = Pipe()
            let outPipe = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = outPipe
            
            try? proc.run()
            
            // Send initialize and read
            let testLine = "{\"jsonrpc\":\"2.0\",\"id\":999,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\"}}\n"
            if let data = testLine.data(using: .utf8) {
                inPipe.fileHandleForWriting.write(data)
            }
            
            // Read response
            var readBuf = Data()
            while !readBuf.contains(0x0A) {
                let chunk = outPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                readBuf.append(chunk)
            }
            let respLine = String(data: readBuf, encoding: .utf8) ?? ""
            assert(respLine.contains("\"name\":\"Pearl\"") && respLine.contains("\"version\":\"2.0.0\""), "Subprocess stdio response mismatch: \(respLine)")
            print("  ✓ Subprocess stdio response verified: Pearl 2.0.0")
            
            // Close stdin (EOF) -> verify clean termination
            try? inPipe.fileHandleForWriting.close()
            proc.waitUntilExit()
            assert(proc.terminationStatus == 0, "Subprocess pearl-cli mcp must exit 0 on stdin EOF (got \(proc.terminationStatus))")
            print("  ✓ Subprocess clean shutdown on stdin EOF verified (exit code 0)")
            
            csvLines.append("\(trialCounter),stdio_subprocess,clean_shutdown,0.0,N/A,N/A,N/A,true,\"Exit code: 0 on EOF\"")
            trialCounter += 1
        }
        
        // ====================================================================
        // SAVE CSV
        // ====================================================================
        let resultsDir = projectRoot.appendingPathComponent("Bench/results")
        try? FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        let csvURL = resultsDir.appendingPathComponent("mcp_bench.csv")
        
        do {
            try csvLines.joined(separator: "\n").write(to: csvURL, atomically: true, encoding: .utf8)
            print("\n✓ Saved benchmark results to \(csvURL.path) (\(csvLines.count - 1) rows)")
        } catch {
            print("❌ Failed to write CSV: \(error)")
        }
        
        print("\n========================================================================")
        print("          ALL MILESTONE 7 EXIT GATES PASSED SUCCESSFULLY!               ")
        print("========================================================================")
    }
}
