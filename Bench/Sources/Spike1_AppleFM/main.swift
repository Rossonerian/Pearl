import Foundation
import FoundationModels

@Generable
public struct ParsedIntent {
    @Guide(description: "Action name: set_volume, get_battery, open_app, close_app, take_screenshot, trash_screenshots, create_reminder, git_status, unknown")
    public var action: String
    
    @Guide(description: "Target or parameter value, e.g. volume level '50', app name 'Safari', reminder text 'Call Mom'")
    public var parameter: String
}

@main
struct Spike1AppleFMRunner {
    static func main() async {
        print("=== Spike 1: Apple Foundation Models Intent Accuracy & Latency (N=50) ===")
        
        let testUtterances: [(text: String, expectedAction: String)] = [
            ("Mute volume", "set_volume"),
            ("Set volume to 50 percent", "set_volume"),
            ("Turn up the volume to 80", "set_volume"),
            ("Volume 0", "set_volume"),
            ("Lower volume to 20", "set_volume"),
            ("What is my battery percentage?", "get_battery"),
            ("Check battery level", "get_battery"),
            ("How much power do I have left?", "get_battery"),
            ("Is my MacBook charging?", "get_battery"),
            ("Battery status please", "get_battery"),
            ("Open Safari", "open_app"),
            ("Launch Visual Studio Code", "open_app"),
            ("Open Mail", "open_app"),
            ("Launch Spotify", "open_app"),
            ("Open Terminal", "open_app"),
            ("Launch Notes", "open_app"),
            ("Open Calendar", "open_app"),
            ("Launch System Settings", "open_app"),
            ("Open Finder", "open_app"),
            ("Open Calculator", "open_app"),
            ("Close Safari", "close_app"),
            ("Quit Mail", "close_app"),
            ("Close Spotify", "close_app"),
            ("Take a screenshot", "take_screenshot"),
            ("Capture screen", "take_screenshot"),
            ("Take screenshot of desktop", "take_screenshot"),
            ("Capture display now", "take_screenshot"),
            ("Grab screenshot", "take_screenshot"),
            ("Clean up my saved screenshots", "trash_screenshots"),
            ("Delete my screenshots from saved folder", "trash_screenshots"),
            ("Move screenshots to trash", "trash_screenshots"),
            ("Clean screenshots folder", "trash_screenshots"),
            ("Trash recent screenshots", "trash_screenshots"),
            ("Create a reminder to buy milk", "create_reminder"),
            ("Remind me to call John at 5pm", "create_reminder"),
            ("Add reminder review pull request", "create_reminder"),
            ("Create reminder submit assignment", "create_reminder"),
            ("Remind me tomorrow morning standup", "create_reminder"),
            ("Check git status for current project", "git_status"),
            ("Show git status", "git_status"),
            ("Is my git working tree clean?", "git_status"),
            ("What changed in this repo?", "git_status"),
            ("Git branch status", "git_status"),
            ("What is the weather in London?", "unknown"),
            ("Who was the third president of the United States?", "unknown"),
            ("Write a poem about Apple Silicon", "unknown"),
            ("Explain quantum computing in one sentence", "unknown"),
            ("Tell me a tech joke", "unknown"),
            ("What is 42 times 18?", "unknown"),
            ("Translate hello to French", "unknown")
        ]
        
        let model = SystemLanguageModel.default
        let session = LanguageModelSession(
            model: model,
            instructions: "You are Pearl's local action resolver. Map user requests into structured tool intents."
        )
        
        var timebaseInfo = mach_timebase_info()
        mach_timebase_info(&timebaseInfo)
        func toMs(_ ticks: UInt64) -> Double {
            let ns = Double(ticks) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
            return ns / 1_000_000.0
        }

        var correctCount = 0
        var latencies: [Double] = []
        latencies.reserveCapacity(testUtterances.count)
        
        var csvLines = ["iteration,utterance,expected_action,parsed_action,parameter,latency_ms,is_correct"]
        
        print("Executing 50 test utterances...")
        for (idx, test) in testUtterances.enumerated() {
            let start = mach_continuous_time()
            do {
                let response = try await session.respond(to: test.text, generating: ParsedIntent.self)
                let end = mach_continuous_time()
                let ms = toMs(end - start)
                latencies.append(ms)
                
                let action = response.content.action.lowercased()
                let isMatch = (action == test.expectedAction.lowercased())
                if isMatch { correctCount += 1 }
                
                print(String(format: "[%02d/50] '%@' -> action=%@ (param=%@) | %.2f ms | %@",
                             idx + 1, test.text, response.content.action, response.content.parameter, ms, isMatch ? "MATCH" : "DIFF"))
                
                let safeText = test.text.replacingOccurrences(of: ",", with: ";")
                let safeParam = response.content.parameter.replacingOccurrences(of: ",", with: ";")
                csvLines.append("\(idx + 1),\"\(safeText)\",\(test.expectedAction),\(response.content.action),\"\(safeParam)\",\(String(format: "%.3f", ms)),\(isMatch)")
            } catch {
                print("Error on utterance \(idx + 1): \(error)")
            }
        }
        
        let accuracy = Double(correctCount) / Double(testUtterances.count) * 100.0
        let sorted = latencies.sorted()
        let p50 = sorted[Int(Double(sorted.count - 1) * 0.50)]
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
        let mean = sorted.reduce(0.0, +) / Double(sorted.count)
        
        print("----------------------------------------------------------------------")
        print(String(format: "Apple FM @Generable Accuracy: %d/50 (%.1f%%)", correctCount, accuracy))
        print(String(format: "Apple FM Latency (N=50): p50=%.2f ms | p95=%.2f ms | p99=%.2f ms | mean=%.2f ms",
                     p50, p95, p99, mean))
        print("----------------------------------------------------------------------")
        
        let outDir = URL(fileURLWithPath: "/Users/rossonerian/Projects/Pearl/Bench/results")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("spike1_apple_fm.csv")
        try? csvLines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
        print("Saved results to \(outURL.path)")
    }
}
