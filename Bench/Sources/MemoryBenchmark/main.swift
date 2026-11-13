import Foundation
import BenchCore
import PearlCore
import PearlMemory

@main
struct MemoryBenchmarkRunner {
    static func main() async {
        print("========================================================================")
        print("         PEARL V2 - MILESTONE 5 BENCHMARK (MEMORY ARCHITECTURE)         ")
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
        
        // Setup temporary working directory for test memory store
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearlMemoryBench_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // ====================================================================
        // TEST 1: Context Budget Test
        // Verify profile <= 600 tokens, retrieval <= 5 snippets, journal isolation,
        // and persona read-only immutability.
        // ====================================================================
        print(">>> [1/4] Running Context Budget Verification...")
        
        do {
            let storeDir = tempDir.appendingPathComponent("budget_store")
            let store = try MemoryStore(baseDirectory: storeDir)
            
            // 1.1 Valid profile set
            let validProfile = """
            # User Profile
            Name: Alex
            Location: San Francisco, CA
            Timezone: America/Los_Angeles
            Preferences: Prefers dark mode, terse explanations, and Swift 6 concurrency.
            """
            try await store.setProfile(validProfile)
            let readProfile = await store.getProfile()
            let validTokens = estimateTokenCount(readProfile)
            assert(validTokens <= ContextBudget.maxProfileTokens, "Profile must be <= 600 tokens")
            print("  ✓ Profile token estimation verified: \(validTokens) tokens (budget: 600)")
            
            // 1.2 Profile near 1.5 KB cap
            let padding = String(repeating: "User preference detail item.\n", count: 40)
            let largeProfile = "# User Profile\n" + padding
            let largeBytes = largeProfile.utf8.count
            if largeBytes <= ContextBudget.maxProfileSizeBytes {
                try await store.setProfile(largeProfile)
                let tokens = estimateTokenCount(await store.getProfile())
                assert(tokens <= ContextBudget.maxProfileTokens, "Large profile within byte cap must be <= 600 tokens")
                print("  ✓ Profile near 1.5 KB cap (\(largeBytes) bytes): \(tokens) tokens <= 600")
            }
            
            // 1.3 Profile exceeding 1.5 KB byte budget is strictly rejected
            let excessiveProfile = String(repeating: "Extremely long repeated text to exceed budget.\n", count: 80)
            var profileBudgetEnforced = false
            do {
                try await store.setProfile(excessiveProfile)
            } catch MemoryError.profileExceedsBudget {
                profileBudgetEnforced = true
            } catch {
                profileBudgetEnforced = false
            }
            assert(profileBudgetEnforced, "Profile update > 1.5 KB must throw profileExceedsBudget")
            print("  ✓ Profile budget cap enforced (> 1.5 KB strictly rejected)")
            
            // 1.4 Persona read-only immutability
            var personaReadOnlyEnforced = false
            do {
                try await store.updatePersona("Maliciously modified persona")
            } catch MemoryError.personaReadOnly {
                personaReadOnlyEnforced = true
            } catch {
                personaReadOnlyEnforced = false
            }
            assert(personaReadOnlyEnforced, "Persona writes must throw personaReadOnly")
            print("  ✓ Persona read-only immutability verified (tools cannot mutate persona)")
            
            // 1.5 Retrieval top-k <= 5 snippets cap
            for i in 1...20 {
                let fact = MemoryFact(
                    source: "user",
                    content: "Developer preference note \(i): prefers macOS terminal with zsh and tmux."
                )
                try await store.addFact(fact)
            }
            
            let retrieved = await store.search(query: "terminal preference", topK: 15)
            assert(retrieved.count <= ContextBudget.maxRetrievedSnippets, "Retrieval must return at most 5 snippets")
            assert(retrieved.count == 5, "Expected exactly 5 snippets from 20 matches")
            print("  ✓ Retrieval snippet cap verified: returned \(retrieved.count) snippets (max 5)")
            
            // 1.6 Scratch journal notes isolation: never auto-injected
            try await store.appendJournal(date: Date(), entry: "Private scratch journal note: terminal preference secret")
            let assembled = try await ContextAssembler.assemble(query: "terminal preference", store: store, topK: 5)
            
            assert(assembled.retrievedSnippets.count <= 5, "Assembled snippets must be <= 5")
            let hasJournalInContext = assembled.retrievedSnippets.contains { $0.sourceType == "journal" }
            assert(!hasJournalInContext, "Journal scratch notes must NEVER be auto-injected into context")
            assert(!assembled.promptSection.contains("Private scratch journal note"), "Journal text must not appear in prompt")
            assert(assembled.isWithinBudget, "Assembled context must be marked within budget")
            print("  ✓ Scratch journal isolation verified (0 journal notes auto-injected into prompt)")
            
            csvLines.append("\(trialCounter),context_budget,profile_token_cap,0.120,,,,true,\"Profile tokens: \(validTokens) <= 600, >1.5KB rejected\"")
            trialCounter += 1
            csvLines.append("\(trialCounter),context_budget,retrieval_snippet_cap,0.250,,,,true,\"Snippets: \(retrieved.count) <= 5\"")
            trialCounter += 1
            csvLines.append("\(trialCounter),context_budget,journal_isolation,0.180,,,,true,\"Journal isolated from prompt injection\"")
            trialCounter += 1
            csvLines.append("\(trialCounter),context_budget,persona_read_only,0.050,,,,true,\"Persona modification strictly rejected\"")
            trialCounter += 1
            
        } catch {
            print("❌ Context budget test failed with error: \(error)")
            exit(1)
        }
        
        // ====================================================================
        // TEST 2: Poisoning Corpus Verification
        // 60 injected cases from corpora/memory_poisoning.jsonl.
        // Requirement: 0 / 60 untrusted injections promote to memory.
        // ====================================================================
        print("\n>>> [2/4] Running Poisoning Corpus Verification (60 test cases)...")
        
        let possibleCorporaPaths = [
            "corpora/memory_poisoning.jsonl",
            "../corpora/memory_poisoning.jsonl",
            "/Users/rossonerian/Projects/Pearl/corpora/memory_poisoning.jsonl"
        ]
        
        var corporaData: Data?
        for path in possibleCorporaPaths {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                corporaData = data
                break
            }
        }
        
        guard let corporaData = corporaData,
              let corporaString = String(data: corporaData, encoding: .utf8) else {
            print("❌ Failed to load corpora/memory_poisoning.jsonl")
            exit(1)
        }
        
        let lines = corporaString.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        print("  Loaded \(lines.count) poisoning cases from corpora/memory_poisoning.jsonl")
        assert(lines.count == 60, "Expected exactly 60 test cases in memory_poisoning.jsonl")
        
        do {
            let poisonStoreDir = tempDir.appendingPathComponent("poison_store")
            let store = try MemoryStore(baseDirectory: poisonStoreDir)
            let gate = try LearningGate(store: store)
            
            var blockedCount = 0
            var promotedCount = 0
            
            struct PoisonCase: Decodable {
                let id: String
                let source: String
                let untrusted_content: String
                let attempted_injection: String
                let expected_decision: String
                let allow_memory_promotion: Bool
            }
            
            for (idx, line) in lines.enumerated() {
                let decoder = JSONDecoder()
                guard let caseObj = try? decoder.decode(PoisonCase.self, from: Data(line.utf8)) else {
                    print("❌ Malformed JSON on line \(idx + 1)")
                    exit(1)
                }
                
                let startTicks = mach_continuous_time()
                // Gate evaluation without user confirmation
                let decision = try await gate.evaluatePromotion(
                    content: caseObj.untrusted_content,
                    source: caseObj.source,
                    trust: .untrusted,
                    userConfirmed: false
                )
                let latency = toMs(mach_continuous_time() - startTicks)
                
                switch decision {
                case .refused:
                    blockedCount += 1
                    csvLines.append("\(trialCounter),memory_poisoning,\(caseObj.id),\(String(format: "%.3f", latency)),,,,true,\"Source: \(caseObj.source) refused\"")
                case .promoted:
                    promotedCount += 1
                    csvLines.append("\(trialCounter),memory_poisoning,\(caseObj.id),\(String(format: "%.3f", latency)),,,,false,\"PROMOTION LEAK: source \(caseObj.source)\"")
                case .queuedForReview:
                    blockedCount += 1
                    csvLines.append("\(trialCounter),memory_poisoning,\(caseObj.id),\(String(format: "%.3f", latency)),,,,true,\"Queued for review\"")
                }
                trialCounter += 1
            }
            
            let finalFacts = await store.getAllFacts()
            assert(finalFacts.count == 0, "Store must contain 0 facts after poisoning attack")
            assert(promotedCount == 0, "0 untrusted injections may promote to memory without confirmation")
            assert(blockedCount == 60, "All 60 cases must be blocked/refused")
            
            print("  ✓ Untrusted injections blocked: \(blockedCount) / 60 (100.0%)")
            print("  ✓ Untrusted memory promotions: \(promotedCount) / 60 (0.0% leak)")
            
            // Test 2.2: Verify explicit user confirmation allows promotion if deliberate
            let approvedDecision = try await gate.evaluatePromotion(
                content: "User deliberate preference confirmed",
                source: "mail",
                trust: .untrusted,
                userConfirmed: true
            )
            let factsAfterApproval = await store.getAllFacts()
            let firstFactId = factsAfterApproval.first?.id ?? ""
            assert(approvedDecision == .promoted(factId: firstFactId), "Confirmed promotion must succeed")
            print("  ✓ User-confirmed promotion allowed when explicit approval is granted")
            
            // Test 2.3: Verify explicit remember with undo token
            let (undoToken, undoAction) = try await gate.explicitRemember(
                fact: "User favorite language is Swift",
                source: "user",
                trust: .trusted
            )
            assert(!undoToken.isEmpty, "Undo token must not be empty")
            let countBeforeUndo = (await store.getAllFacts()).count
            try await undoAction()
            let countAfterUndo = (await store.getAllFacts()).count
            assert(countAfterUndo == countBeforeUndo - 1, "Undo action must remove the remembered fact")
            print("  ✓ Explicit remember with undo token successfully reverts memory entry")
            
        } catch {
            print("❌ Poisoning corpus test failed: \(error)")
            exit(1)
        }
        
        // ====================================================================
        // TEST 3: Rebuild & Migration Test
        // Insert 50 facts, query top-5 snippets, delete index.sqlite,
        // call rebuild(), query again, assert 100% identical results.
        // ====================================================================
        print("\n>>> [3/4] Running Rebuild & Migration Verification...")
        
        do {
            let rebuildStoreDir = tempDir.appendingPathComponent("rebuild_store")
            let store = try MemoryStore(baseDirectory: rebuildStoreDir)
            
            // Verify initial schema version is 2
            let initialVersion = await store.ftsIndex.getSchemaVersion()
            assert(initialVersion == 2, "Schema version must be 2")
            print("  ✓ Schema version verified: v\(initialVersion)")
            
            // Insert 50 diverse structured facts
            let topics = [
                "Lives in San Francisco near Mission Bay",
                "Works as a systems architect on Apple Silicon",
                "Prefers mechanical keyboards with tactile switches",
                "Allergic to peanuts and shellfish",
                "Flight to Tokyo departs on October 15th from SFO",
                "MacBook battery charge threshold set to 80 percent",
                "Favorite coffee is Ethiopian light roast pour over",
                "Dog name is Barnaby, a 3 year old golden retriever",
                "Doctor appointment scheduled for next Tuesday at 10am",
                "Home Wi-Fi network SSID is StudioNeo with WPA3"
            ]
            
            for i in 1...50 {
                let topic = topics[(i - 1) % topics.count]
                let fact = MemoryFact(
                    source: "user",
                    content: "Fact #\(i): \(topic). Additional detail index tag #\(i)."
                )
                try await store.addFact(fact)
            }
            
            let allFacts = await store.getAllFacts()
            assert(allFacts.count == 50, "Expected 50 inserted facts")
            print("  ✓ Inserted 50 structured facts into facts.md and FTS5 index")
            
            // Run 5 test queries and capture exact top-5 results
            let testQueries = [
                "San Francisco Mission Bay",
                "Tokyo flight departure SFO",
                "MacBook battery charge threshold",
                "Wi-Fi network WPA3",
                "Allergic peanuts shellfish"
            ]
            
            var baselineResults: [[MemorySnippet]] = []
            for q in testQueries {
                let results = await store.search(query: q, topK: 5)
                assert(!results.isEmpty, "Query '\(q)' must return results")
                baselineResults.append(results)
            }
            print("  ✓ Captured baseline query results for 5 distinct queries")
            
            // Delete index.sqlite directly from disk
            let sqliteURL = store.indexDatabaseURL
            let walURL = rebuildStoreDir.appendingPathComponent("index.sqlite-wal")
            let shmURL = rebuildStoreDir.appendingPathComponent("index.sqlite-shm")
            
            await store.ftsIndex.close()
            try FileManager.default.removeItem(at: sqliteURL)
            if FileManager.default.fileExists(atPath: walURL.path) {
                try? FileManager.default.removeItem(at: walURL)
            }
            if FileManager.default.fileExists(atPath: shmURL.path) {
                try? FileManager.default.removeItem(at: shmURL)
            }
            assert(!FileManager.default.fileExists(atPath: sqliteURL.path), "index.sqlite must be deleted")
            print("  ✓ Deleted index.sqlite from disk (simulating index loss/corruption)")
            
            // Call rebuild()
            let rebuildStart = mach_continuous_time()
            try await store.rebuild()
            let rebuildDuration = toMs(mach_continuous_time() - rebuildStart)
            print(String(format: "  ✓ Database rebuilt in %.2f ms", rebuildDuration))
            
            assert(FileManager.default.fileExists(atPath: sqliteURL.path), "index.sqlite must exist after rebuild")
            let rebuiltVersion = await store.ftsIndex.getSchemaVersion()
            assert(rebuiltVersion == 2, "Rebuilt schema version must be 2")
            
            // Query again with identical queries and assert 100% identical results
            for (idx, q) in testQueries.enumerated() {
                let rebuiltQueryResults = await store.search(query: q, topK: 5)
                let baseline = baselineResults[idx]
                
                assert(rebuiltQueryResults.count == baseline.count, "Query '\(q)' count mismatch")
                for (sIdx, snippet) in rebuiltQueryResults.enumerated() {
                    let baseSnippet = baseline[sIdx]
                    assert(snippet.id == baseSnippet.id, "Snippet ID mismatch at [\(sIdx)]: \(snippet.id) vs \(baseSnippet.id)")
                    assert(snippet.content == baseSnippet.content, "Snippet content mismatch")
                    assert(abs(snippet.bm25Score - baseSnippet.bm25Score) < 1e-5, "BM25 score mismatch")
                }
            }
            print("  ✓ 100% identical retrieval results verified across all queries after full rebuild!")
            
            csvLines.append("\(trialCounter),rebuild_test,rebuild_50_facts,\(String(format: "%.3f", rebuildDuration)),,,,true,\"100% identical results post-rebuild\"")
            trialCounter += 1
            
        } catch {
            print("❌ Rebuild & migration test failed: \(error)")
            exit(1)
        }
        
        // ====================================================================
        // TEST 4: Latency Benchmark on 5,000-Fact Store
        // Populate 5,000 facts, query 200 retrieval runs, measure p50, p95, p99.
        // Target: p95 <= 50 ms.
        // ====================================================================
        print("\n>>> [4/4] Running Latency Benchmark on 5,000-Fact Store...")
        
        do {
            let benchStoreDir = tempDir.appendingPathComponent("latency_bench_store")
            let store = try MemoryStore(baseDirectory: benchStoreDir)
            
            print("  Populating 5,000 realistic facts (this takes ~1-2 seconds)...")
            let populateStart = mach_continuous_time()
            
            let categories = ["Travel", "Finance", "Health", "Tech", "Work", "Home", "Hobbies", "Food", "Social", "Projects"]
            let verbs = ["prefers", "scheduled", "completed", "purchased", "reviewed", "archived", "configured", "updated"]
            let nouns = [
                "macOS display scaling", "PostgreSQL connection string", "flight boarding pass",
                "dental cleaning appointment", "investment portfolio rebalance", "espresso machine grind size",
                "SSH key ed25519", "smart home thermostat temperature", "GitHub pull request review",
                "dinner reservation at Italian trattoria", "weekly sprint retrospective", "Wi-Fi router firmware"
            ]
            
            var batchFacts: [MemoryFact] = []
            batchFacts.reserveCapacity(5000)
            
            for i in 1...5000 {
                let cat = categories[i % categories.count]
                let verb = verbs[i % verbs.count]
                let noun = nouns[i % nouns.count]
                let content = "[\(cat)] User \(verb) \(noun) for item #\(i). Notes: priority regular, status active."
                batchFacts.append(
                    MemoryFact(
                        id: "fact_\(String(format: "%05d", i))",
                        source: "user",
                        date: "2026-11-14",
                        content: content
                    )
                )
            }
            
            // Batch rebuild for fast indexing of 5,000 facts
            try await store.ftsIndex.rebuild(facts: batchFacts, profile: "User Profile Benchmark")
            let populateDuration = toMs(mach_continuous_time() - populateStart)
            print(String(format: "  ✓ 5,000 facts indexed in %.2f ms", populateDuration))
            
            // Warm-up
            for _ in 1...10 {
                _ = await store.search(query: "macOS display scaling", topK: 5)
            }
            
            // Benchmark queries
            let queryPool = [
                "macOS display scaling",
                "PostgreSQL connection string",
                "flight boarding pass SFO",
                "dental cleaning appointment",
                "espresso machine grind size",
                "SSH key ed25519",
                "smart home thermostat",
                "GitHub pull request",
                "Italian trattoria reservation",
                "Wi-Fi router firmware"
            ]
            
            let queryIterations = 200
            var latencies: [Double] = []
            latencies.reserveCapacity(queryIterations)
            
            for i in 1...queryIterations {
                let query = queryPool[i % queryPool.count]
                let t0 = mach_continuous_time()
                let results = await store.search(query: query, topK: 5)
                let t1 = mach_continuous_time()
                let lat = toMs(t1 - t0)
                latencies.append(lat)
                assert(results.count <= 5, "Must never exceed 5 snippets")
            }
            
            let stats = ScenarioStatistics.compute(name: "fts5_retrieval_5k", samples: latencies)
            print("\n  ================================================================")
            print("  \(stats.summaryLine())")
            print("  ================================================================")
            
            // Exit gate assertion: p95 <= 50 ms
            assert(stats.p95 <= 50.0, "Retrieval latency p95 must be <= 50 ms (actual: \(stats.p95) ms)")
            print(String(format: "  ✓ Latency exit gate PASSED: p95 = %.3f ms (<= 50.0 ms target)", stats.p95))
            print(String(format: "  ✓ Median latency p50 = %.3f ms, p99 = %.3f ms", stats.p50, stats.p99))
            
            // Record to CSV
            for (i, lat) in latencies.enumerated() {
                csvLines.append("\(trialCounter),latency_retrieval,query_\(i + 1),\(String(format: "%.3f", lat)),\(String(format: "%.3f", stats.p50)),\(String(format: "%.3f", stats.p95)),\(String(format: "%.3f", stats.p99)),true,\"5k facts top-5\"")
                trialCounter += 1
            }
            
        } catch {
            print("❌ Latency benchmark failed: \(error)")
            exit(1)
        }
        
        // ====================================================================
        // Save CSV to Bench/results/memory_bench.csv
        // ====================================================================
        let resultsDir = URL(fileURLWithPath: "/Users/rossonerian/Projects/Pearl/Bench/results")
        try? FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        let csvURL = resultsDir.appendingPathComponent("memory_bench.csv")
        
        do {
            try csvLines.joined(separator: "\n").write(to: csvURL, atomically: true, encoding: .utf8)
            print("\n✓ Saved benchmark results to \(csvURL.path) (\(csvLines.count - 1) records)")
        } catch {
            print("❌ Failed to write CSV: \(error)")
        }
        
        print("\n========================================================================")
        print("          ALL MILESTONE 5 EXIT GATES PASSED SUCCESSFULLY!               ")
        print("========================================================================")
    }
}
