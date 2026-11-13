import Foundation
import PearlCore

public final class GitTool: PearlTool {
    public let name = "git"
    public let description = "Check repository status and active branch in registered projects or current directory"
    public let tier = ToolTier.t3WorkspaceChanges
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let repoPath = args["path"] ?? FileManager.default.currentDirectoryPath
        
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
                return ToolResult(success: false, message: "Directory is not a git repository.")
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
