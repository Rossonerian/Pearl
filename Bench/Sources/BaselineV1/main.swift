import Foundation

@main
struct BaselineV1Fast {
    static func main() {
        let n = 100
        var timebaseInfo = mach_timebase_info()
        mach_timebase_info(&timebaseInfo)
        func toMs(_ ticks: UInt64) -> Double {
            let ns = Double(ticks) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
            return ns / 1_000_000.0
        }

        print("=== Benchmarking Pearl V1 Baseline on MacBook Neo ===")
        
        // 1. Deterministic Fast-Path Dispatch (N=100)
        var fastPathLatencies: [Double] = []
        fastPathLatencies.reserveCapacity(n)
        print("Measuring V1 Fast-Path Deterministic Dispatch ('battery', N=\(n))...")
        for _ in 0..<n {
            let start = mach_continuous_time()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["/Users/rossonerian/Projects/Pearl/legacy/bin/pearl", "-q", "battery"]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            try? task.run()
            task.waitUntilExit()
            let end = mach_continuous_time()
            fastPathLatencies.append(toMs(end - start))
        }
        
        let sorted = fastPathLatencies.sorted()
        let p50 = sorted[Int(Double(sorted.count - 1) * 0.50)]
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
        let minVal = sorted.first!
        let maxVal = sorted.last!
        let meanVal = sorted.reduce(0.0, +) / Double(sorted.count)
        
        print(String(format: "V1 Fast-Path Dispatch (N=%d): p50=%.2f ms | p95=%.2f ms | p99=%.2f ms | min/max=%.2f/%.2f ms | mean=%.2f ms",
                     n, p50, p95, p99, minVal, maxVal, meanVal))
        
        // 2. Measure V1 Telemetry Overhead (N=20)
        var telemetryLatencies: [Double] = []
        for _ in 0..<20 {
            let start = mach_continuous_time()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["/Users/rossonerian/Projects/Pearl/legacy/bin/pearl-telemetry"]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            try? task.run()
            task.waitUntilExit()
            let end = mach_continuous_time()
            telemetryLatencies.append(toMs(end - start))
        }
        let telSorted = telemetryLatencies.sorted()
        let telP50 = telSorted[Int(Double(telSorted.count - 1) * 0.50)]
        print(String(format: "V1 Telemetry Collection (N=20): p50=%.2f ms | mean=%.2f ms", telP50, telSorted.reduce(0.0, +) / 20.0))

        // Export CSV
        var csvLines = ["iteration,v1_fast_path_ms,v1_telemetry_ms"]
        for i in 0..<n {
            let telVal = i < telemetryLatencies.count ? String(format: "%.3f", telemetryLatencies[i]) : ""
            csvLines.append("\(i + 1),\(String(format: "%.3f", fastPathLatencies[i])),\(telVal)")
        }
        
        let outDir = URL(fileURLWithPath: "/Users/rossonerian/Projects/Pearl/Bench/results")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("v1_baseline.csv")
        try? csvLines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
        print("Saved V1 baseline to \(outURL.path)")
    }
}
