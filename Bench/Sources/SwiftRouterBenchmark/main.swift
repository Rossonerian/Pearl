import Foundation

public struct RouterMatch {
    public let tool: String
    public let arg: String
    public let confidence: Double
}

public final class DeterministicRouter {
    private let volumeRegex = try! NSRegularExpression(pattern: #"(?:set|turn|change)?\s*volume\s*(?:to)?\s*(\d+)"#, options: .caseInsensitive)
    private let muteRegex = try! NSRegularExpression(pattern: #"\b(?:mute|silence|unmute)\b"#, options: .caseInsensitive)
    private let batteryRegex = try! NSRegularExpression(pattern: #"\b(?:battery|power|charge)\b"#, options: .caseInsensitive)
    private let screenshotRegex = try! NSRegularExpression(pattern: #"\b(?:screenshot|capture screen|screen shot)\b"#, options: .caseInsensitive)
    private let openAppRegex = try! NSRegularExpression(pattern: #"\b(?:open|launch)\s+([A-Za-z0-9 ]+)"#, options: .caseInsensitive)

    public func match(utterance: String) -> RouterMatch? {
        let range = NSRange(location: 0, length: utterance.utf16.count)
        
        if let m = volumeRegex.firstMatch(in: utterance, range: range) {
            let valRange = m.range(at: 1)
            let val = (utterance as NSString).substring(with: valRange)
            return RouterMatch(tool: "set_volume", arg: val, confidence: 1.0)
        }
        if muteRegex.firstMatch(in: utterance, range: range) != nil {
            return RouterMatch(tool: "set_volume", arg: "0", confidence: 1.0)
        }
        if batteryRegex.firstMatch(in: utterance, range: range) != nil {
            return RouterMatch(tool: "get_battery", arg: "", confidence: 1.0)
        }
        if screenshotRegex.firstMatch(in: utterance, range: range) != nil {
            return RouterMatch(tool: "take_screenshot", arg: "", confidence: 1.0)
        }
        if let m = openAppRegex.firstMatch(in: utterance, range: range) {
            let appRange = m.range(at: 1)
            let app = (utterance as NSString).substring(with: appRange).trimmingCharacters(in: .whitespaces)
            return RouterMatch(tool: "open_app", arg: app, confidence: 1.0)
        }
        return nil
    }
}

@main
struct SwiftRouterBenchmark {
    static func main() {
        let router = DeterministicRouter()
        let n = 100
        var timebaseInfo = mach_timebase_info()
        mach_timebase_info(&timebaseInfo)
        func toMs(_ ticks: UInt64) -> Double {
            let ns = Double(ticks) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
            return ns / 1_000_000.0
        }

        let testUtterance = "set volume to 65"
        var latencies: [Double] = []
        latencies.reserveCapacity(n)

        print("=== Benchmarking Swift Deterministic Router (N=\(n)) ===")
        for _ in 0..<n {
            let start = mach_continuous_time()
            let res = router.match(utterance: testUtterance)
            let end = mach_continuous_time()
            _ = res
            latencies.append(toMs(end - start))
        }

        let sorted = latencies.sorted()
        let p50 = sorted[Int(Double(sorted.count - 1) * 0.50)]
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
        let minVal = sorted.first!
        let maxVal = sorted.last!
        let meanVal = sorted.reduce(0.0, +) / Double(sorted.count)

        print(String(format: "Swift Router Matching (N=%d): p50=%.4f ms | p95=%.4f ms | p99=%.4f ms | min=%.4f ms | max=%.4f ms | mean=%.4f ms",
                     n, p50, p95, p99, minVal, maxVal, meanVal))

        var csvLines = ["iteration,scenario,latency_ms,p50_ms,p95_ms,p99_ms"]
        for (i, val) in latencies.enumerated() {
            csvLines.append("\(i + 1),swift_deterministic_router,\(String(format: "%.5f", val)),\(String(format: "%.5f", p50)),\(String(format: "%.5f", p95)),\(String(format: "%.5f", p99))")
        }

        let outDir = URL(fileURLWithPath: "/Users/rossonerian/Projects/Pearl/Bench/results")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("swift_router_bench.csv")
        try? csvLines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
        print("Saved Swift router benchmark to \(outURL.path)")
    }
}
