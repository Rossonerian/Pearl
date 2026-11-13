import Foundation
import PearlCore

public final class GitStatusTool: PearlTool {
    public let name = "git_status"
    public let description = "Check repository status and active branch in registered projects or current directory"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let defaultPath: String = {
            if FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/.git") {
                return FileManager.default.currentDirectoryPath
            }
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let candidate = homeDir + "/Projects/Pearl"
            if FileManager.default.fileExists(atPath: candidate + "/.git") {
                return candidate
            }
            return FileManager.default.currentDirectoryPath
        }()
        
        let repoPath = args["path"] ?? defaultPath
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        task.arguments = ["status", "--porcelain", "-b"]
        
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            guard task.terminationStatus == 0 else {
                return ToolResult(success: false, message: "Directory '\(repoPath)' is not a git repository.")
            }
            
            let lines = output.components(separatedBy: .newlines)
            let branchLine = lines.first ?? "## main"
            let branch = branchLine.replacingOccurrences(of: "## ", with: "")
            let modifiedFiles = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            
            if modifiedFiles.isEmpty {
                return ToolResult(success: true, message: "Git working tree is clean on branch \(branch).")
            } else {
                return ToolResult(success: true, message: "Branch \(branch) has \(modifiedFiles.count) modified or untracked file(s).")
            }
        } catch {
            return ToolResult(success: false, message: "Git error: \(error.localizedDescription)")
        }
    }
}
