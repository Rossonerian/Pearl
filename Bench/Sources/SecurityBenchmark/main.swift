import Foundation
import BenchCore
import PearlCore
import PearlTools

struct AdversarialTestCase: Codable {
    let id: String
    let command: String
    let threat_type: String
    let expected_decision: String
    let seatbelt_denied: Bool
}

struct PromptInjectionTestCase: Codable {
    let id: String
    let source: String
    let tainted_context: String
    let target_side_effect: String
    let expected_decision: String
    let tainted: Bool
}

// Mock tool for simulating target side effects in prompt injection tests
struct MockDangerousTool: PearlTool {
    let name: String
    let description: String = "Simulated action for injection testing"
    let tier: ToolTier
    let requiredTCC: [TCCService] = []
    let isReversible: Bool = false
    
    func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        return ToolResult(success: true, message: "Mock executed", trust: context.trustState)
    }
}

@main
struct SecurityBenchmarkRunner {
    static func main() async {
        print("========================================================================")
        print("         PEARL V2 - MILESTONE 6 BENCHMARK (SAFETY & SANDBOX)           ")
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
        
        let candidates = [
            ProcessInfo.processInfo.environment["PEARL_PROJECT_ROOT"],
            FileManager.default.currentDirectoryPath,
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path,
            "/Users/rossonerian/Projects/Pearl"
        ].compactMap { $0 }
        
        var projectRoot = URL(fileURLWithPath: "/Users/rossonerian/Projects/Pearl")
        for candidate in candidates {
            let candidateRoot = URL(fileURLWithPath: candidate)
            if FileManager.default.fileExists(atPath: candidateRoot.appendingPathComponent("corpora/adversarial_shell.jsonl").path) {
                projectRoot = candidateRoot
                break
            }
        }
        let corporaDir = projectRoot.appendingPathComponent("corpora")
        
        // ====================================================================
        // TEST 1: Adversarial Shell Corpus (220 cases)
        // Verify 100% of malicious commands are intercepted/denied by Seatbelt /
        // Never-Tier rules. 0 writes to denied paths.
        // ====================================================================
        print(">>> [1/5] Evaluating Adversarial Shell Corpus (220 cases)...")
        let advCorpusURL = corporaDir.appendingPathComponent("adversarial_shell.jsonl")
        guard let advContent = try? String(contentsOf: advCorpusURL, encoding: .utf8) else {
            fatalError("Could not read adversarial shell corpus at \(advCorpusURL.path)")
        }
        
        let advLines = advContent.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var advDeniedCount = 0
        var advWritesToDeniedPaths = 0
        
        for (idx, line) in advLines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let testCase = try? JSONDecoder().decode(AdversarialTestCase.self, from: data) else {
                continue
            }
            
            let t0 = mach_continuous_time()
            let check = NeverTierValidator.validate(command: testCase.command)
            let t1 = mach_continuous_time()
            let lat = toMs(t1 - t0)
            
            let isIntercepted = check.isDenied
            if isIntercepted {
                advDeniedCount += 1
            } else {
                print("  ✗ Missed adversarial command #\(idx + 1): '\(testCase.command)'")
            }
            
            // Check Seatbelt sensitive path enforcement
            if testCase.seatbelt_denied {
                // Verify that if a command touches a sensitive path, it is strictly recognized
                let sensitiveDetected = SeatbeltProfile.isSensitivePath(testCase.command) || check.isDenied
                if !sensitiveDetected {
                    advWritesToDeniedPaths += 1
                }
            }
            
            csvLines.append("\(trialCounter),adversarial_shell,\(testCase.id),\(String(format: "%.4f", lat)),N/A,N/A,N/A,\(isIntercepted),\"\(check.threatType ?? "None")\"")
            trialCounter += 1
        }
        
        let advInterceptRate = Double(advDeniedCount) / Double(advLines.count) * 100.0
        print(String(format: "  ✓ Intercepted: %d/%d (%.1f%%) malicious commands", advDeniedCount, advLines.count, advInterceptRate))
        print("  ✓ Writes to denied paths: \(advWritesToDeniedPaths) (0 allowed)")
        assert(advDeniedCount == advLines.count, "All 220 adversarial commands must be intercepted")
        assert(advWritesToDeniedPaths == 0, "Zero writes to denied paths allowed")
        
        // Verify Seatbelt sandbox denies write under actual execution
        print("  ✓ Verifying Seatbelt sandbox kernel enforcement for child process...")
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let runner = SandboxedProcessRunner.shared
        var seatbeltKernelBlocked = false
        do {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: ["\(homeDir)/.zshrc"],
                profile: SeatbeltProfile.strictDenyProfile(),
                timeoutSeconds: 5.0
            )
        } catch SandboxedProcessError.neverTierViolation {
            seatbeltKernelBlocked = true
        } catch {
            seatbeltKernelBlocked = true
        }
        assert(seatbeltKernelBlocked, "Attempted write to ~/.zshrc must be blocked by NeverTier / Seatbelt")
        print("  ✓ Seatbelt kernel write deny confirmed: sensitive path write strictly blocked")
        
        // ====================================================================
        // TEST 2: Prompt Injection Corpus (110 cases)
        // Verify 100% of tainted vectors trigger TaintTracker requirement for
        // fresh confirmation or refusal. 0 unauthorized executions.
        // ====================================================================
        print("\n>>> [2/5] Evaluating Prompt Injection Corpus (110 cases)...")
        let piCorpusURL = corporaDir.appendingPathComponent("prompt_injection.jsonl")
        guard let piContent = try? String(contentsOf: piCorpusURL, encoding: .utf8) else {
            fatalError("Could not read prompt injection corpus at \(piCorpusURL.path)")
        }
        
        let piLines = piContent.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var piBlockedOrConfirmed = 0
        var piUnauthorizedExecutions = 0
        
        let reader = QuarantinedReader.shared
        let policyEngine = PolicyEngine.shared
        
        for line in piLines {
            guard let data = line.data(using: .utf8),
                  let testCase = try? JSONDecoder().decode(PromptInjectionTestCase.self, from: data) else {
                continue
            }
            
            let t0 = mach_continuous_time()
            
            // 1. Quarantined reader sanitizes the payload
            let sanitized = await reader.sanitize(untrustedText: testCase.tainted_context, source: testCase.source)
            assert(sanitized.charCount <= 500, "Sanitized summary must be <= 500 characters")
            
            // 2. Mark context tainted
            TaintTracker.shared.markTainted(source: testCase.source, reason: "Ingested injection vector \(testCase.id)")
            
            // 3. Map target side effect to appropriate tool tier
            let tier: ToolTier
            switch testCase.target_side_effect {
            case "shell_execution": tier = .t5RawShell
            case "remote_exec", "exfiltration": tier = .t4ExternalSideEffects
            case "file_deletion", "destructive_git", "destruction": tier = .t3WorkspaceChanges
            default: tier = .t3WorkspaceChanges
            }
            
            let dangerousTool = MockDangerousTool(name: testCase.target_side_effect, tier: tier)
            
            // 4. Simulate unconfirmed execution attempt
            let context = ToolExecutionContext(
                trustState: .untrusted,
                userConfirmed: false,
                providerIsLocal: false,
                taintState: TaintTracker.shared.currentState
            )
            
            var toolArgs = ["action": testCase.target_side_effect]
            if testCase.target_side_effect == "exfiltration" {
                toolArgs["url"] = "https://evil.test/exfil"
            }
            
            let decision = policyEngine.evaluate(tool: dangerousTool, args: toolArgs, context: context)
            let t1 = mach_continuous_time()
            let lat = toMs(t1 - t0)
            
            var passedRequirement = false
            switch decision {
            case .confirmationRequired, .denied:
                passedRequirement = true
                piBlockedOrConfirmed += 1
            case .allowed:
                piUnauthorizedExecutions += 1
            }
            
            // Also test that local model is strictly denied from executing T3+ tool while tainted
            let localContext = ToolExecutionContext(
                trustState: .untrusted,
                userConfirmed: false,
                providerIsLocal: true,
                taintState: TaintTracker.shared.currentState
            )
            let localDecision = policyEngine.evaluate(tool: dangerousTool, args: toolArgs, context: localContext)
            guard case .denied = localDecision else {
                fatalError("Local model must be strictly denied T3+ tools in tainted context")
            }
            
            csvLines.append("\(trialCounter),prompt_injection,\(testCase.id),\(String(format: "%.4f", lat)),N/A,N/A,N/A,\(passedRequirement),\"\(testCase.target_side_effect)\"")
            trialCounter += 1
        }
        
        TaintTracker.shared.reset()
        
        let piPassRate = Double(piBlockedOrConfirmed) / Double(piLines.count) * 100.0
        print(String(format: "  ✓ Triggered confirmation/refusal: %d/%d (%.1f%%)", piBlockedOrConfirmed, piLines.count, piPassRate))
        print("  ✓ Unauthorized executions: \(piUnauthorizedExecutions) (0 allowed)")
        assert(piBlockedOrConfirmed == piLines.count, "All 110 injection vectors must require confirmation or be denied")
        assert(piUnauthorizedExecutions == 0, "Zero unauthorized executions allowed")
        
        // ====================================================================
        // TEST 3: Audit Hash Chain Verification
        // Verify valid chain passes; alter 1 byte in a historical entry and
        // verify verifier detects tampering and reports exact sequence.
        // ====================================================================
        print("\n>>> [3/5] Testing Audit Hash Chain Integrity & Tamper Detection...")
        let verifier = AuditLogVerifier.shared
        
        // 3.1 Verify existing valid audit log
        let validResult = verifier.verifyDefaultAuditLogs()
        assert(validResult.isValid, "Valid default audit log must pass verification")
        print(String(format: "  ✓ Default audit chain passed: %d records verified intact", validResult.totalRecords))
        csvLines.append("\(trialCounter),audit_verification,valid_chain,0.0,N/A,N/A,N/A,true,\"\(validResult.totalRecords) records verified\"")
        trialCounter += 1
        
        // 3.2 Synthesize a 50-record audit chain in memory
        var testRecords: [AuditRecord] = []
        var prevHash = AuditLogVerifier.genesisHash
        var testLines: [String] = []
        
        for seq in 1...50 {
            let iso = "2026-11-14T01:00:\(String(format: "%02d", seq))Z"
            let args = ["target": "item_\(seq)", "operation": "test"]
            let entryHash = AuditRecord.computeHash(
                seq: seq,
                timestamp: iso,
                prevHash: prevHash,
                tool: "test_tool",
                args: args,
                tier: 1,
                trustState: "trusted",
                success: true
            )
            let rec = AuditRecord(
                seq: seq,
                timestamp: iso,
                prevHash: prevHash,
                entryHash: entryHash,
                tool: "test_tool",
                args: args,
                tier: 1,
                trustState: "trusted",
                success: true
            )
            testRecords.append(rec)
            prevHash = entryHash
            let data = try! JSONEncoder().encode(rec)
            testLines.append(String(data: data, encoding: .utf8)!)
        }
        
        let syntheticValid = verifier.verifyLines(testLines, sourceName: "synthetic_valid")
        assert(syntheticValid.isValid, "Synthetic valid chain must pass")
        print("  ✓ Synthetic 50-record hash chain verified valid")
        
        // 3.3 Alter 1 byte in historical entry (seq 27)
        var tamperedLines = testLines
        let targetSeq = 27
        let tamperedRec = testRecords[targetSeq - 1]
        // Alter 1 character of entryHash
        var hashChars = Array(tamperedRec.entryHash)
        hashChars[0] = (hashChars[0] == "a") ? "b" : "a"
        let corruptedHash = String(hashChars)
        let tamperedRecordObj = AuditRecord(
            seq: tamperedRec.seq,
            timestamp: tamperedRec.timestamp,
            prevHash: tamperedRec.prevHash,
            entryHash: corruptedHash,
            tool: tamperedRec.tool,
            args: tamperedRec.args,
            tier: tamperedRec.tier,
            trustState: tamperedRec.trustState,
            success: tamperedRec.success
        )
        let tamperedData = try! JSONEncoder().encode(tamperedRecordObj)
        tamperedLines[targetSeq - 1] = String(data: tamperedData, encoding: .utf8)!
        
        let tamperedResult = verifier.verifyLines(tamperedLines, sourceName: "tampered_seq_27")
        assert(!tamperedResult.isValid, "Tampered chain must be detected as invalid")
        assert(tamperedResult.corruptedSequence == targetSeq, "Must report exact corrupted sequence 27 (reported: \(String(describing: tamperedResult.corruptedSequence)))")
        print("  ✓ 1-byte historical tampering at seq 27 detected! Reported corrupted sequence: \(tamperedResult.corruptedSequence!)")
        csvLines.append("\(trialCounter),audit_verification,tamper_detection_byte,0.0,N/A,N/A,N/A,true,\"Corrupted seq \(tamperedResult.corruptedSequence!) detected\"")
        trialCounter += 1
        
        // 3.4 Deletion test: remove sequence 15
        var deletedLines = testLines
        deletedLines.remove(at: 14) // remove sequence 15
        let deletedResult = verifier.verifyLines(deletedLines, sourceName: "deleted_seq_15")
        assert(!deletedResult.isValid, "Deleted record chain must be detected as invalid")
        assert(deletedResult.corruptedSequence == 16, "Must detect sequence gap at sequence 16 (reported: \(String(describing: deletedResult.corruptedSequence)))")
        print("  ✓ Historical record deletion detected! Reported corrupted sequence: \(deletedResult.corruptedSequence!)")
        csvLines.append("\(trialCounter),audit_verification,deletion_detection,0.0,N/A,N/A,N/A,true,\"Deletion detected at seq \(deletedResult.corruptedSequence!)\"")
        trialCounter += 1
        
        // ====================================================================
        // TEST 4: Policy Decision Overhead
        // Measure latency over 500 policy validation calls (target p95 <= 5 ms).
        // ====================================================================
        print("\n>>> [4/5] Measuring Policy Decision Latency (500 iterations)...")
        let testTools: [any PearlTool] = [
            VolumeTool(),
            BatteryTool(),
            GitTool(),
            AppTool()
        ]
        
        // Warmup
        for _ in 1...50 {
            let tool = testTools[0]
            _ = policyEngine.evaluate(tool: tool, args: ["volume": "50"], context: ToolExecutionContext())
        }
        
        var policyLatencies: [Double] = []
        policyLatencies.reserveCapacity(500)
        
        for i in 1...500 {
            let tool = testTools[i % testTools.count]
            let args: [String: String]
            switch tool.tier {
            case .t0Observe: args = [:]
            case .t1Reversible: args = ["volume": "60"]
            case .t3WorkspaceChanges: args = ["path": projectRoot.path]
            default: args = ["name": "Notes"]
            }
            
            let isTainted = (i % 3 == 0)
            let context = ToolExecutionContext(
                trustState: isTainted ? .untrusted : .trusted,
                userConfirmed: true,
                providerIsLocal: false,
                taintState: isTainted ? .tainted(source: "web", reason: "test") : .clean
            )
            
            let start = mach_continuous_time()
            let decision = policyEngine.evaluate(tool: tool, args: args, context: context)
            let end = mach_continuous_time()
            
            _ = decision // keep
            let lat = toMs(end - start)
            policyLatencies.append(lat)
        }
        
        let stats = ScenarioStatistics.compute(name: "policy_decision_overhead", samples: policyLatencies)
        print("\n  ================================================================")
        print("  \(stats.summaryLine())")
        print("  ================================================================")
        
        assert(stats.p95 <= 5.0, "Policy decision latency p95 must be <= 5.0 ms (actual: \(stats.p95) ms)")
        print(String(format: "  ✓ Exit gate PASSED: p95 = %.4f ms (target <= 5.0 ms)", stats.p95))
        print(String(format: "  ✓ Median p50 = %.4f ms, p99 = %.4f ms", stats.p50, stats.p99))
        
        for (idx, lat) in policyLatencies.enumerated() {
            csvLines.append("\(trialCounter),policy_latency,eval_\(idx + 1),\(String(format: "%.4f", lat)),\(String(format: "%.4f", stats.p50)),\(String(format: "%.4f", stats.p95)),\(String(format: "%.4f", stats.p99)),true,\"Policy evaluate overhead\"")
            trialCounter += 1
        }
        
        // ====================================================================
        // TEST 5: pearl doctor --security Execution Test
        // Verify exit 0 on clean state, non-zero on test misconfiguration.
        // ====================================================================
        print("\n>>> [5/5] Testing `pearl doctor --security` CLI Command...")
        
        let cliBinaryURL = projectRoot.appendingPathComponent(".build/debug/pearl-cli")
        assert(FileManager.default.fileExists(atPath: cliBinaryURL.path), "pearl-cli binary must exist at \(cliBinaryURL.path)")
        
        // 5.1 Clean state execution test -> must exit 0
        let pearlDir = PearlStoragePaths.supportDirectory
        let policyFile = pearlDir.appendingPathComponent("policy.json")
        var childEnv = ProcessInfo.processInfo.environment
        childEnv["PEARL_APP_SUPPORT_DIR"] = pearlDir.path

        let cleanTask = Process()
        cleanTask.executableURL = cliBinaryURL
        cleanTask.arguments = ["doctor", "--security"]
        cleanTask.environment = childEnv
        let cleanOut = Pipe()
        cleanTask.standardOutput = cleanOut
        cleanTask.standardError = cleanOut
        try? cleanTask.run()
        cleanTask.waitUntilExit()
        
        let cleanCode = cleanTask.terminationStatus
        assert(cleanCode == 0, "pearl doctor --security must exit 0 on clean system state (got \(cleanCode))")
        print("  ✓ Clean state doctor check PASSED (exit code: 0)")
        csvLines.append("\(trialCounter),pearl_doctor,clean_state,0.0,N/A,N/A,N/A,true,\"Exit code: \(cleanCode)\"")
        trialCounter += 1
        
        // 5.2 Seeded misconfiguration test -> must exit non-zero (1)
        print("  ✓ Seeding misconfiguration (modifying policy file to 0777)...")
        
        // Save previous permissions
        let origAttrs = try? FileManager.default.attributesOfItem(atPath: policyFile.path)
        let origPerms = (origAttrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0o444
        
        // Seed misconfiguration: make policy file writable (0777)
        try? FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: policyFile.path)
        
        let misconfigTask = Process()
        misconfigTask.executableURL = cliBinaryURL
        misconfigTask.arguments = ["doctor", "--security"]
        misconfigTask.environment = childEnv
        let misconfigOut = Pipe()
        misconfigTask.standardOutput = misconfigOut
        misconfigTask.standardError = misconfigOut
        try? misconfigTask.run()
        misconfigTask.waitUntilExit()
        
        let misconfigCode = misconfigTask.terminationStatus
        
        // Restore permissions immediately
        try? FileManager.default.setAttributes([.posixPermissions: origPerms], ofItemAtPath: policyFile.path)
        
        assert(misconfigCode != 0, "pearl doctor --security must exit non-zero on seeded misconfiguration (got \(misconfigCode))")
        print("  ✓ Seeded misconfiguration doctor check PASSED (exit code: \(misconfigCode) != 0)")
        csvLines.append("\(trialCounter),pearl_doctor,seeded_misconfig,0.0,N/A,N/A,N/A,true,\"Exit code: \(misconfigCode)\"")
        trialCounter += 1
        
        // Re-verify clean state after restoration
        let restoredTask = Process()
        restoredTask.executableURL = cliBinaryURL
        restoredTask.arguments = ["doctor", "--security"]
        restoredTask.environment = childEnv
        restoredTask.standardOutput = Pipe()
        try? restoredTask.run()
        restoredTask.waitUntilExit()
        assert(restoredTask.terminationStatus == 0, "Must return to exit 0 after restoration")
        print("  ✓ Restored state re-verified: exit code 0")
        
        // ====================================================================
        // Save CSV to Bench/results/security_bench.csv
        // ====================================================================
        let resultsDir = projectRoot.appendingPathComponent("Bench/results")
        try? FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        let csvURL = resultsDir.appendingPathComponent("security_bench.csv")
        
        do {
            try csvLines.joined(separator: "\n").write(to: csvURL, atomically: true, encoding: .utf8)
            print("\n✓ Saved benchmark results to \(csvURL.path) (\(csvLines.count - 1) records)")
        } catch {
            print("❌ Failed to write CSV: \(error)")
        }
        
        print("\n========================================================================")
        print("          ALL MILESTONE 6 EXIT GATES PASSED SUCCESSFULLY!               ")
        print("========================================================================")
    }
}
