import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import IOKit.ps
import PearlCore
import PearlTools

@main
struct ActionBenchmarkRunner {
    static func main() {
        print("=== Benchmark of 5 Representative Actions: osascript vs NSAppleScript vs Native (MacBook Neo) ===")
        
        var timebaseInfo = mach_timebase_info()
        mach_timebase_info(&timebaseInfo)
        func toMs(_ ticks: UInt64) -> Double {
            let ns = Double(ticks) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
            return ns / 1_000_000.0
        }

        let n = 20
        
        // 1. Action: Set Volume to 50%
        print("\n1. Volume Control (Set volume to 50%):")
        
        // (a) osascript CLI
        var osascriptVol: [Double] = []
        for _ in 0..<n {
            let start = mach_continuous_time()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "set volume output volume 50"]
            try? task.run()
            task.waitUntilExit()
            let end = mach_continuous_time()
            osascriptVol.append(toMs(end - start))
        }
        let osaVolP50 = osascriptVol.sorted()[n / 2]
        print(String(format: "   osascript CLI:         p50 = %.2f ms", osaVolP50))
        
        // (b) cached NSAppleScript
        let cachedVolScript = NSAppleScript(source: "set volume output volume 50")!
        _ = cachedVolScript.compileAndReturnError(nil)
        var nsAppleVol: [Double] = []
        for _ in 0..<n {
            let start = mach_continuous_time()
            var err: NSDictionary?
            cachedVolScript.executeAndReturnError(&err)
            let end = mach_continuous_time()
            nsAppleVol.append(toMs(end - start))
        }
        let nsVolP50 = nsAppleVol.sorted()[n / 2]
        print(String(format: "   cached NSAppleScript:  p50 = %.2f ms", nsVolP50))
        
        // (c) Native CoreAudio (VolumeTool)
        let volTool = VolumeTool()
        var nativeVol: [Double] = []
        for _ in 0..<n {
            let start = mach_continuous_time()
            volTool.setVolume(0.5)
            let end = mach_continuous_time()
            nativeVol.append(toMs(end - start))
        }
        let natVolP50 = nativeVol.sorted()[n / 2]
        print(String(format: "   Native CoreAudio:      p50 = %.4f ms (Speedup: %.1fx vs osascript)", natVolP50, osaVolP50 / max(0.0001, natVolP50)))
        
        // 2. Action: Frontmost Application Name
        print("\n2. Frontmost Application Name:")
        
        // (a) osascript CLI
        var osascriptFront: [Double] = []
        for _ in 0..<n {
            let start = mach_continuous_time()
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "tell application \"System Events\" to get name of first process whose frontmost is true"]
            task.standardOutput = Pipe()
            try? task.run()
            task.waitUntilExit()
            let end = mach_continuous_time()
            osascriptFront.append(toMs(end - start))
        }
        let osaFrontP50 = osascriptFront.sorted()[n / 2]
        print(String(format: "   osascript CLI:         p50 = %.2f ms", osaFrontP50))
        
        // (b) Native NSWorkspace
        var nativeFront: [Double] = []
        for _ in 0..<n {
            let start = mach_continuous_time()
            _ = NSWorkspace.shared.frontmostApplication?.localizedName
            let end = mach_continuous_time()
            nativeFront.append(toMs(end - start))
        }
        let natFrontP50 = nativeFront.sorted()[n / 2]
        print(String(format: "   Native NSWorkspace:    p50 = %.4f ms (Speedup: %.1fx vs osascript)", natFrontP50, osaFrontP50 / max(0.0001, natFrontP50)))
        
        // 3. Action: Battery Info
        print("\n3. Battery Info:")
        let battTool = BatteryTool()
        var nativeBatt: [Double] = []
        for _ in 0..<n {
            let start = mach_continuous_time()
            Task {
                _ = try? await battTool.execute(args: [:], context: ToolExecutionContext())
            }
            let end = mach_continuous_time()
            nativeBatt.append(toMs(end - start))
        }
        let natBattP50 = nativeBatt.sorted()[n / 2]
        print(String(format: "   Native IOKit:          p50 = %.4f ms", natBattP50))
        
        // Export CSV comparison
        var csvLines = ["action,osascript_p50_ms,cached_applescript_p50_ms,native_swift_p50_ms,speedup_factor"]
        csvLines.append("set_volume,\(String(format: "%.3f", osaVolP50)),\(String(format: "%.3f", nsVolP50)),\(String(format: "%.4f", natVolP50)),\(String(format: "%.1f", osaVolP50 / max(0.0001, natVolP50)))")
        csvLines.append("frontmost_app,\(String(format: "%.3f", osaFrontP50)),N/A,\(String(format: "%.4f", natFrontP50)),\(String(format: "%.1f", osaFrontP50 / max(0.0001, natFrontP50)))")
        csvLines.append("battery_status,N/A,N/A,\(String(format: "%.4f", natBattP50)),N/A")
        
        let outDir = URL(fileURLWithPath: "/Users/rossonerian/Projects/Pearl/Bench/results")
        let outURL = outDir.appendingPathComponent("action_comparison.csv")
        try? csvLines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
        print("\nSaved action comparison CSV to: \(outURL.path)")
    }
}
