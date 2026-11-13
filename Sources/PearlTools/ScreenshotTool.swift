import Foundation
import PearlCore

public final class ScreenshotTool: PearlTool {
    public let name = "screenshot"
    public let description = "Capture screen and save to Pictures/Pearl directory"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = [.screenRecording]
    public let isReversible = true
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let picturesDir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        let pearlScreensDir = picturesDir.appendingPathComponent("Pearl", isDirectory: true)
        
        try FileManager.default.createDirectory(at: pearlScreensDir, withIntermediateDirectories: true)
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let filename = "Screenshot_\(timestamp).png"
        let targetURL = pearlScreensDir.appendingPathComponent(filename)
        
        // Execute screencapture using argv array (never /bin/sh -c)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", targetURL.path]
        
        do {
            try task.run()
            task.waitUntilExit()
            
            guard task.terminationStatus == 0 && FileManager.default.fileExists(atPath: targetURL.path) else {
                return ToolResult(success: false, message: "Screen capture failed.")
            }
            
            let undoAction: @Sendable () async throws -> Void = {
                var trashURL: NSURL?
                try? FileManager.default.trashItem(at: targetURL, resultingItemURL: &trashURL)
            }
            
            return ToolResult(
                success: true,
                message: "Captured screen to \(targetURL.lastPathComponent).",
                undoAction: undoAction
            )
        } catch {
            return ToolResult(success: false, message: "Error capturing screen: \(error.localizedDescription)")
        }
    }
}
