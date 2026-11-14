import Foundation
import PearlCore

struct CorpusItem: Codable {
    let utterance: String
    let expected_tool: String?
    let expected_arg: String?
}

@main
struct RouterEvaluationRunner {
    static func main() {
        let candidates = [
            ProcessInfo.processInfo.environment["PEARL_PROJECT_ROOT"],
            FileManager.default.currentDirectoryPath,
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path,
            "/Users/rossonerian/Projects/Pearl"
        ].compactMap { $0 }
        
        var projectRoot = URL(fileURLWithPath: "/Users/rossonerian/Projects/Pearl")
        for candidate in candidates {
            let candidateRoot = URL(fileURLWithPath: candidate)
            if FileManager.default.fileExists(atPath: candidateRoot.appendingPathComponent("corpora/golden_commands.jsonl").path) {
                projectRoot = candidateRoot
                break
            }
        }
        let corpusURL = projectRoot.appendingPathComponent("corpora/golden_commands.jsonl")
        guard let data = try? Data(contentsOf: corpusURL),
              let content = String(data: data, encoding: .utf8) else {
            print("Failed to load corpus from \(corpusURL.path)")
            exit(1)
        }
        
        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var items: [CorpusItem] = []
        for line in lines {
            if let item = try? JSONDecoder().decode(CorpusItem.self, from: Data(line.utf8)) {
                items.append(item)
            }
        }
        
        let router = DeterministicRouter.shared
        let total = items.count
        var correct = 0
        var falseExecutionsOnNegation = 0
        var wrongActionCount = 0
        
        var timebaseInfo = mach_timebase_info()
        mach_timebase_info(&timebaseInfo)
        func toMs(_ ticks: UInt64) -> Double {
            let ns = Double(ticks) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
            return ns / 1_000_000.0
        }

        var latencies: [Double] = []
        latencies.reserveCapacity(total)
        var csvLines = ["iteration,utterance,expected_tool,resolved_tool,is_correct,latency_ms"]
        
        print("=== Evaluating Deterministic Router on \(total) Utterances ===")
        
        for (i, item) in items.enumerated() {
            let start = mach_continuous_time()
            let resolved = router.resolve(utterance: item.utterance)
            let end = mach_continuous_time()
            
            let latency = toMs(end - start)
            latencies.append(latency)
            
            let resolvedTool = resolved?.toolName
            let expectedTool = item.expected_tool
            
            var isMatch = false
            if expectedTool == nil {
                // Expected to NOT route to any tool (negation or out-of-domain)
                if resolvedTool == nil {
                    isMatch = true
                } else {
                    if item.utterance.contains("don't") || item.utterance.contains("dont") || item.utterance.contains("do not") {
                        falseExecutionsOnNegation += 1
                    }
                    wrongActionCount += 1
                }
            } else {
                if resolvedTool == expectedTool {
                    isMatch = true
                } else if resolvedTool != nil {
                    wrongActionCount += 1
                }
            }
            
            if isMatch {
                correct += 1
            }
            
            let safeUtt = item.utterance.replacingOccurrences(of: ",", with: ";")
            csvLines.append("\(i + 1),\"\(safeUtt)\",\(expectedTool ?? "none"),\(resolvedTool ?? "none"),\(isMatch),\(String(format: "%.4f", latency))")
        }
        
        let sorted = latencies.sorted()
        let p50 = sorted[Int(Double(sorted.count - 1) * 0.50)]
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
        let mean = sorted.reduce(0.0, +) / Double(sorted.count)
        
        let accuracy = Double(correct) / Double(total) * 100.0
        let wrongActionRate = Double(wrongActionCount) / Double(total) * 100.0
        
        print(String(format: "Corpus Evaluation (N=%d): Accuracy: %.2f%% (%d/%d)", total, accuracy, correct, total))
        print(String(format: "Wrong-Action Rate: %.2f%% (Target <= 1.0%%) -> %@", wrongActionRate, wrongActionRate <= 1.0 ? "PASS" : "FAIL"))
        print(String(format: "False-Executions on Negations: %d (Target: 0) -> %@", falseExecutionsOnNegation, falseExecutionsOnNegation == 0 ? "PASS" : "FAIL"))
        print(String(format: "Router Latency: p50=%.4f ms | p95=%.4f ms | p99=%.4f ms | mean=%.4f ms", p50, p95, p99, mean))
        
        let outDir = projectRoot.appendingPathComponent("Bench/results")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("router_eval.csv")
        try? csvLines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
        print("Saved router evaluation CSV to: \(outURL.path)")
    }
}
