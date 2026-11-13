import AppKit
import Foundation

@main
struct HUDShowBenchmark {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        
        // Target MacBook Neo top-center pill
        let screenRect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1470, height: 956)
        let pillWidth: CGFloat = 380
        let pillHeight: CGFloat = 48
        let pillX = (screenRect.width - pillWidth) / 2.0
        let pillY = screenRect.maxY - pillHeight - 6.0
        
        let panel = NSPanel(
            contentRect: NSRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hasShadow = true
        
        // Host a lightweight AppKit view
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight))
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 24
        visualEffect.layer?.masksToBounds = true
        panel.contentView = visualEffect
        
        var timebaseInfo = mach_timebase_info()
        mach_timebase_info(&timebaseInfo)
        func toMs(_ ticks: UInt64) -> Double {
            let ns = Double(ticks) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
            return ns / 1_000_000.0
        }

        print("Warming up pre-created NSPanel...")
        panel.orderFront(nil)
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        panel.orderOut(nil)
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        
        let n = 100
        var showLatencies: [Double] = []
        showLatencies.reserveCapacity(n)
        
        print("Benchmarking NSPanel show latency (N=\(n))...")
        for _ in 0..<n {
            let start = mach_continuous_time()
            panel.orderFront(nil)
            // Force display pipeline flush
            CATransaction.flush()
            let end = mach_continuous_time()
            
            let ms = toMs(end - start)
            showLatencies.append(ms)
            
            // Brief dwell then hide
            panel.orderOut(nil)
            CATransaction.flush()
        }
        
        let sorted = showLatencies.sorted()
        func percentile(_ p: Double) -> Double {
            let idx = Int(Double(sorted.count - 1) * p)
            return sorted[idx]
        }
        
        let p50 = percentile(0.50)
        let p95 = percentile(0.95)
        let p99 = percentile(0.99)
        let minVal = sorted.first!
        let maxVal = sorted.last!
        let meanVal = sorted.reduce(0.0, +) / Double(n)
        
        print(String(format: "HUD Show Latency (N=%d): p50=%.3f ms | p95=%.3f ms | p99=%.3f ms | min=%.3f ms | max=%.3f ms | mean=%.3f ms",
                     n, p50, p95, p99, minVal, maxVal, meanVal))
        
        // Export CSV
        var csvLines = ["iteration,scenario,latency_ms,p50_ms,p95_ms,p99_ms"]
        for (i, val) in showLatencies.enumerated() {
            csvLines.append("\(i + 1),hud_panel_show,\(String(format: "%.4f", val)),\(String(format: "%.4f", p50)),\(String(format: "%.4f", p95)),\(String(format: "%.4f", p99))")
        }
        
        let outDir = URL(fileURLWithPath: "/Users/rossonerian/Projects/Pearl/Bench/results")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("spike4_hud_show.csv")
        try? csvLines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
        print("Saved results to \(outURL.path)")
    }
}
