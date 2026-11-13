import Foundation

public struct BenchmarkSample: Codable, Sendable {
    public let iteration: Int
    public let latencyMs: Double
    public let ttftMs: Double?
    public let memoryFootprintBytes: UInt64?
    public let thermalState: String
    public let timestamp: Date
    
    public init(iteration: Int, latencyMs: Double, ttftMs: Double? = nil, memoryFootprintBytes: UInt64? = nil, thermalState: String, timestamp: Date = Date()) {
        self.iteration = iteration
        self.latencyMs = latencyMs
        self.ttftMs = ttftMs
        self.memoryFootprintBytes = memoryFootprintBytes
        self.thermalState = thermalState
        self.timestamp = timestamp
    }
}

public struct ScenarioStatistics: Sendable {
    public let scenarioName: String
    public let n: Int
    public let p50: Double
    public let p95: Double
    public let p99: Double
    public let min: Double
    public let max: Double
    public let mean: Double
    public let stdDev: Double
    
    public static func compute(name: String, samples: [Double]) -> ScenarioStatistics {
        guard !samples.isEmpty else {
            return ScenarioStatistics(scenarioName: name, n: 0, p50: 0, p95: 0, p99: 0, min: 0, max: 0, mean: 0, stdDev: 0)
        }
        let sorted = samples.sorted()
        let count = sorted.count
        
        func percentile(_ p: Double) -> Double {
            let index = Int(Double(count - 1) * p)
            return sorted[index]
        }
        
        let sum = sorted.reduce(0.0, +)
        let mean = sum / Double(count)
        let variance = sorted.map { pow($0 - mean, 2.0) }.reduce(0.0, +) / Double(count)
        let stdDev = sqrt(variance)
        
        return ScenarioStatistics(
            scenarioName: name,
            n: count,
            p50: percentile(0.50),
            p95: percentile(0.95),
            p99: percentile(0.99),
            min: sorted.first!,
            max: sorted.last!,
            mean: mean,
            stdDev: stdDev
        )
    }
    
    public func summaryLine() -> String {
        return String(format: "[%@] N=%d | p50: %.2f ms | p95: %.2f ms | p99: %.2f ms | min/max: %.2f/%.2f ms | mean: %.2f ms (±%.2f)",
                      scenarioName, n, p50, p95, p99, min, max, mean, stdDev)
    }
}

public enum CSVExporter {
    public static func exportSamples(to fileURL: URL, scenario: String, samples: [BenchmarkSample]) throws {
        var lines = ["iteration,scenario,latency_ms,ttft_ms,footprint_bytes,thermal_state,iso_timestamp"]
        let isoFormatter = ISO8601DateFormatter()
        for s in samples {
            let ttftStr = s.ttftMs.map { String(format: "%.3f", $0) } ?? ""
            let fpStr = s.memoryFootprintBytes.map { String($0) } ?? ""
            lines.append("\(s.iteration),\(scenario),\(String(format: "%.3f", s.latencyMs)),\(ttftStr),\(fpStr),\(s.thermalState),\(isoFormatter.string(from: s.timestamp))")
        }
        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
