import Foundation
import PearlCore

// MARK: - ListShortcutsTool

public final class ListShortcutsTool: PearlTool {
    public let name = "list_shortcuts"
    public let description = "List installed user shortcuts from the macOS Shortcuts database"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return []
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let shortcutsURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        guard FileManager.default.fileExists(atPath: shortcutsURL.path) else {
            return ToolResult(success: false, message: "The '/usr/bin/shortcuts' CLI is not available on this macOS system.")
        }
        
        let task = Process()
        task.executableURL = shortcutsURL
        task.arguments = ["list"]
        
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        
        do {
            try task.run()
            
            // Wait with timeout
            let timeoutSeconds: TimeInterval = 6.0
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while task.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
            if task.isRunning {
                task.terminate()
                return ToolResult(success: false, message: "Listing shortcuts timed out after \(Int(timeoutSeconds)) seconds.")
            }
            
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard task.terminationStatus == 0 else {
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return ToolResult(success: false, message: "Failed to list shortcuts: \(errText.isEmpty ? "exit status \(task.terminationStatus)" : errText)")
            }
            
            if output.isEmpty {
                return ToolResult(success: true, message: "No user shortcuts found.")
            }
            
            let lines = output.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let formatted = "Installed Shortcuts (\(lines.count)):\n" + lines.map { "• \($0)" }.joined(separator: "\n")
            return ToolResult(success: true, message: formatted)
        } catch {
            return ToolResult(success: false, message: "Error executing shortcuts CLI: \(error.localizedDescription)")
        }
    }
}

// MARK: - RunShortcutTool

public final class RunShortcutTool: PearlTool {
    public let name = "run_shortcut"
    public let description = "Run an existing macOS Shortcut by name (workspace change)"
    public let tier = ToolTier.t3WorkspaceChanges
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "name", type: "string", description: "Name of the shortcut to run", isRequired: true),
            ToolArgumentDescriptor(name: "input", type: "string", description: "Optional text input to pass to the shortcut", isRequired: false)
        ]
    }
    
    public init() {}
    
    /// Checks for dangerous shell injection or control characters in shortcut names.
    public static func isSafeShortcutName(_ name: String) -> Bool {
        let forbiddenCharacters = CharacterSet(charactersIn: ";|&$`\n\r><\\\"'\0")
        return name.rangeOfCharacter(from: forbiddenCharacters) == nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let rawName = args["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else {
            return ToolResult(success: false, message: "Missing required 'name' argument.")
        }
        
        guard Self.isSafeShortcutName(rawName) else {
            return ToolResult(success: false, message: "Invalid shortcut name: contains prohibited shell control characters.")
        }
        
        let shortcutsURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        guard FileManager.default.fileExists(atPath: shortcutsURL.path) else {
            return ToolResult(success: false, message: "The '/usr/bin/shortcuts' CLI is not available on this macOS system.")
        }
        
        let task = Process()
        task.executableURL = shortcutsURL
        task.arguments = ["run", rawName]
        
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr
        
        do {
            try task.run()
            
            if let inputText = args["input"], !inputText.isEmpty {
                if let inputData = inputText.data(using: .utf8) {
                    stdin.fileHandleForWriting.write(inputData)
                }
            }
            try? stdin.fileHandleForWriting.close()
            
            // Wait with timeout
            let timeoutSeconds: TimeInterval = 20.0
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while task.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }
            if task.isRunning {
                task.terminate()
                return ToolResult(success: false, message: "Shortcut '\(rawName)' timed out after \(Int(timeoutSeconds)) seconds.")
            }
            
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let outText = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard task.terminationStatus == 0 else {
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = errText.isEmpty ? (outText.isEmpty ? "exit status \(task.terminationStatus)" : outText) : errText
                return ToolResult(success: false, message: "Shortcut '\(rawName)' execution failed: \(detail)")
            }
            
            let msg = outText.isEmpty ? "Successfully executed shortcut '\(rawName)'." : "Executed '\(rawName)':\n\(outText)"
            return ToolResult(success: true, message: msg)
        } catch {
            return ToolResult(success: false, message: "Failed to run shortcut '\(rawName)': \(error.localizedDescription)")
        }
    }
}
