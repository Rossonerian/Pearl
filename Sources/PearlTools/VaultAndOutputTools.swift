import Foundation
import PearlCore
import PearlMemory

// MARK: - VaultListTool

public final class VaultListTool: PearlTool {
    public let name = "vault_list"
    public let description = "List all markdown notes in the Obsidian-compatible Pearl vault"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "folder", type: "string", description: "Optional subfolder to list", isRequired: false)
        ]
    }
    
    public let vaultManager: VaultManager
    
    public init(vaultManager: VaultManager = .shared) {
        self.vaultManager = vaultManager
    }
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let allNotes = vaultManager.listNotes()
        let notes: [String]
        if let folder = args["folder"]?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
            let prefix = folder.hasSuffix("/") ? folder : "\(folder)/"
            notes = allNotes.filter { $0.hasPrefix(prefix) }
        } else {
            notes = allNotes
        }
        
        if notes.isEmpty {
            return ToolResult(success: true, message: "No notes found in vault.")
        }
        
        let formatted = "Vault notes (\(notes.count)):\n" + notes.joined(separator: "\n")
        return ToolResult(success: true, message: formatted)
    }
}

// MARK: - VaultReadTool

public final class VaultReadTool: PearlTool {
    public let name = "vault_read"
    public let description = "Read note content from the Obsidian-compatible Pearl vault"
    public let tier = ToolTier.t2ReadPersonal
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "name", type: "string", description: "Note name or relative path in vault", isRequired: true)
        ]
    }
    
    public let vaultManager: VaultManager
    
    public init(vaultManager: VaultManager = .shared) {
        self.vaultManager = vaultManager
    }
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let noteName = args["name"] ?? args["path"] ?? args["file"],
              !noteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(success: false, message: "Missing required 'name' argument.")
        }
        
        guard let content = vaultManager.readNote(name: noteName) else {
            return ToolResult(success: false, message: "Note '\(noteName)' not found in vault.")
        }
        
        return ToolResult(success: true, message: content)
    }
}

// MARK: - VaultWriteTool

public final class VaultWriteTool: PearlTool {
    public let name = "vault_write"
    public let description = "Write or update a markdown note in the Obsidian-compatible Pearl vault with frontmatter and undo"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = []
    public let isReversible = true
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "name", type: "string", description: "Note name or relative path", isRequired: true),
            ToolArgumentDescriptor(name: "content", type: "string", description: "Note body content", isRequired: true),
            ToolArgumentDescriptor(name: "tags", type: "string", description: "Optional comma-separated tags", isRequired: false),
            ToolArgumentDescriptor(name: "wikilinks", type: "string", description: "Optional comma-separated wikilinks", isRequired: false)
        ]
    }
    
    public let vaultManager: VaultManager
    public let undoJournal: UndoJournal?
    
    public init(vaultManager: VaultManager = .shared, undoJournal: UndoJournal? = nil) {
        self.vaultManager = vaultManager
        self.undoJournal = undoJournal
    }
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let name = args["name"] ?? args["path"] ?? args["file"],
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(success: false, message: "Missing required 'name' argument.")
        }
        guard let content = args["content"],
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(success: false, message: "Missing required 'content' argument.")
        }
        
        let tags: [String]
        if let rawTags = args["tags"] {
            tags = rawTags.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            tags = ["agent-memory"]
        }
        
        let wikilinks: [String]
        if let rawLinks = args["wikilinks"] {
            wikilinks = rawLinks.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            wikilinks = []
        }
        
        let priorContent = vaultManager.readNote(name: name)
        let resolvedURL: URL
        do {
            let (url, _) = try vaultManager.resolveAndSanitize(name: name)
            resolvedURL = url
            _ = try vaultManager.writeNote(name: name, content: content, tags: tags, wikilinks: wikilinks)
        } catch {
            return ToolResult(success: false, message: "Failed to write note: \(error.localizedDescription)")
        }
        
        let targetURL = resolvedURL
        let capturedPrior = priorContent
        let undoAction: @Sendable () async throws -> Void = {
            if let prior = capturedPrior {
                try? prior.write(to: targetURL, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: targetURL)
            }
        }
        
        let journal = self.undoJournal ?? UndoJournal.shared
        await journal.register(toolName: self.name, undoAction: undoAction)
        
        return ToolResult(
            success: true,
            message: "Successfully wrote note '\(name)' to vault.",
            undoAction: undoAction
        )
    }
}

// MARK: - VaultSearchTool

public final class VaultSearchTool: PearlTool {
    public let name = "vault_search"
    public let description = "Search markdown notes in the Obsidian-compatible Pearl vault"
    public let tier = ToolTier.t2ReadPersonal
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "query", type: "string", description: "Search query across titles and contents", isRequired: true)
        ]
    }
    
    public let vaultManager: VaultManager
    
    public init(vaultManager: VaultManager = .shared) {
        self.vaultManager = vaultManager
    }
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let query = args["query"],
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(success: false, message: "Missing required 'query' argument.")
        }
        
        let hits = vaultManager.searchNotes(query: query)
        if hits.isEmpty {
            return ToolResult(success: true, message: "No notes found matching query '\(query)'.")
        }
        
        let formatted = "Found \(hits.count) note(s):\n" + hits.map { "- \($0.file): \($0.snippet)" }.joined(separator: "\n")
        return ToolResult(success: true, message: formatted)
    }
}

// MARK: - OutputFileTool

public final class OutputFileTool: PearlTool {
    public let name = "write_output_file"
    public let description = "Safely write curated artifacts and reports to ~/Documents/PearlOutput with undo support"
    public let tier = ToolTier.t3WorkspaceChanges
    public let requiredTCC: [TCCService] = []
    public let isReversible = true
    
    public static let allowedExtensions: Set<String> = [".md", ".txt", ".csv", ".json", ".html"]
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "filename", type: "string", description: "Filename (.md, .txt, .csv, .json, .html)", isRequired: true),
            ToolArgumentDescriptor(name: "content", type: "string", description: "Content to write", isRequired: true)
        ]
    }
    
    public let outputDirectory: URL
    public let undoJournal: UndoJournal?
    
    public init(outputDirectory: URL? = nil, undoJournal: UndoJournal? = nil) {
        let defaultDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/PearlOutput", isDirectory: true)
        self.outputDirectory = outputDirectory ?? defaultDir
        self.undoJournal = undoJournal
    }
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let rawName = args["filename"] ?? args["name"] ?? args["file"],
              !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(success: false, message: "Missing required 'filename' argument.")
        }
        guard let content = args["content"] else {
            return ToolResult(success: false, message: "Missing required 'content' argument.")
        }
        
        // 1. Block slashes / directory traversal
        if rawName.contains("/") || rawName.contains("\\") {
            return ToolResult(success: false, message: "Filename must not contain slashes or directory paths.")
        }
        if rawName.contains("..") {
            return ToolResult(success: false, message: "Filename must not contain path traversal '..'.")
        }
        
        // 2. Strip control characters
        let sanitizedName = rawName.components(separatedBy: CharacterSet.controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedName.isEmpty else {
            return ToolResult(success: false, message: "Filename cannot be empty.")
        }
        
        // 3. Validate allowed extension
        let lowerName = sanitizedName.lowercased()
        var hasValidExtension = false
        for ext in Self.allowedExtensions {
            if lowerName.hasSuffix(ext) {
                hasValidExtension = true
                break
            }
        }
        guard hasValidExtension else {
            return ToolResult(
                success: false,
                message: "Disallowed file extension. Allowed extensions are: \(Self.allowedExtensions.sorted().joined(separator: ", "))"
            )
        }
        
        let targetURL = outputDirectory.appendingPathComponent(sanitizedName).standardizedFileURL
        
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            
            let priorData = try? Data(contentsOf: targetURL)
            
            // Atomic write: write to .tmp in same directory, then rename
            let tempURL = outputDirectory.appendingPathComponent(".\(sanitizedName).\(UUID().uuidString).tmp")
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            
            if FileManager.default.fileExists(atPath: targetURL.path) {
                _ = try? FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: targetURL)
            
            let fileURL = targetURL
            let capturedPrior = priorData
            let undoAction: @Sendable () async throws -> Void = {
                if let prior = capturedPrior {
                    try prior.write(to: fileURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
            
            let journal = self.undoJournal ?? UndoJournal.shared
            await journal.register(toolName: self.name, undoAction: undoAction)
            
            return ToolResult(
                success: true,
                message: "Successfully wrote output file to '\(targetURL.path)'.",
                undoAction: undoAction
            )
        } catch {
            return ToolResult(success: false, message: "Failed to write output file: \(error.localizedDescription)")
        }
    }
}
