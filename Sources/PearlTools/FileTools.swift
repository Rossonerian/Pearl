import Foundation
import PearlCore

/// Errors that can occur during folder allowlist validation.
public enum FolderValidationError: Error, LocalizedError, Equatable, Sendable {
    case blockedByNeverTier(reason: String)
    case outsideAllowedFolders(path: String)
    case sensitivePathBlocked(path: String)
    case pathDoesNotExist(path: String)
    case emptyPath
    
    public var errorDescription: String? {
        switch self {
        case .blockedByNeverTier(let reason):
            return "Path blocked by NeverTier policy: \(reason)"
        case .outsideAllowedFolders(let path):
            return "Path '\(path)' is outside the allowed directories."
        case .sensitivePathBlocked(let path):
            return "Path '\(path)' is a sensitive location and cannot be accessed."
        case .pathDoesNotExist(let path):
            return "Path '\(path)' does not exist."
        case .emptyPath:
            return "Path cannot be empty."
        }
    }
}

/// Enforces folder allowlisting, symlink resolution, and NeverTier sensitive path blocking.
public struct FolderAllowlistValidator: Sendable {
    public let allowedFolders: [String]
    
    public static let defaultAllowedFolders: [String] = [
        "~/Documents", "~/Downloads", "~/Desktop", "~/Projects"
    ]
    
    public init(allowedFolders: [String]? = nil) {
        self.allowedFolders = allowedFolders ?? Self.defaultAllowedFolders
    }
    
    /// Checks whether a given path violates hard security policies (NeverTier, sensitive directories, secrets).
    public static func isNeverAllowed(path: String) -> (blocked: Bool, reason: String?) {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        let lowerResolved = resolved.lowercased()
        let lowerExpanded = expanded.lowercased()
        
        // 1. Direct NeverTier evaluation
        let neverCheck = NeverTierValidator.validate(command: resolved)
        if neverCheck.isDenied {
            return (true, neverCheck.reason ?? "Never-Tier policy violation")
        }
        let expNeverCheck = NeverTierValidator.validate(command: expanded)
        if expNeverCheck.isDenied {
            return (true, expNeverCheck.reason ?? "Never-Tier policy violation")
        }
        
        // 2. Prohibited directories and paths
        let forbiddenPatterns = [
            "/.ssh", "/.aws", "/.gnupg", "/system", "/library", "/etc", "/private/etc", "keychain"
        ]
        
        for pattern in forbiddenPatterns {
            if lowerResolved.contains(pattern) || lowerExpanded.contains(pattern) {
                return (true, "NeverTier: Access to '\(pattern)' is strictly forbidden")
            }
        }
        
        // 3. Prohibit .env and secret files
        let fileName = URL(fileURLWithPath: resolved).lastPathComponent.lowercased()
        let expFileName = URL(fileURLWithPath: expanded).lastPathComponent.lowercased()
        if fileName == ".env" || fileName.hasPrefix(".env.") || expFileName == ".env" || expFileName.hasPrefix(".env.") {
            return (true, "NeverTier: Access to environment secrets file (\(fileName)) is strictly forbidden")
        }
        
        // 4. Seatbelt sensitive path check
        if SeatbeltProfile.isSensitivePath(resolved) || SeatbeltProfile.isSensitivePath(expanded) {
            return (true, "NeverTier: Path is recognized as a sensitive system or user location")
        }
        
        return (false, nil)
    }
    
    /// Resolves symlinks and ensures the target resides strictly within an expanded allowed folder,
    /// rejecting any symlink escape or NeverTier violation.
    public func validate(path: String) -> Result<String, FolderValidationError> {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyPath)
        }
        
        let expanded = (trimmed as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        
        // Check NeverTier / sensitive location on resolved and expanded paths
        let (blockedResolved, reasonResolved) = Self.isNeverAllowed(path: resolved)
        if blockedResolved {
            return .failure(.blockedByNeverTier(reason: reasonResolved ?? "Sensitive path blocked"))
        }
        let (blockedExpanded, reasonExpanded) = Self.isNeverAllowed(path: expanded)
        if blockedExpanded {
            return .failure(.blockedByNeverTier(reason: reasonExpanded ?? "Sensitive path blocked"))
        }
        
        // Verify resolved path resides within one of the expanded allowed folders
        var isWithinAllowlist = false
        for allowed in allowedFolders {
            let expAllowed = (allowed as NSString).expandingTildeInPath
            let resAllowed = URL(fileURLWithPath: expAllowed).resolvingSymlinksInPath().path
            
            if resolved == resAllowed || resolved.hasPrefix(resAllowed + "/") {
                isWithinAllowlist = true
                break
            }
        }
        
        guard isWithinAllowlist else {
            return .failure(.outsideAllowedFolders(path: resolved))
        }
        
        return .success(resolved)
    }
    
    public static func validate(path: String, allowedFolders: [String]? = nil) -> Result<String, FolderValidationError> {
        let validator = FolderAllowlistValidator(allowedFolders: allowedFolders)
        return validator.validate(path: path)
    }
}

// MARK: - SearchFilesTool

public final class SearchFilesTool: PearlTool {
    public let name = "search_files"
    public let description = "Search allowed directories for files matching substring or extension"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "query", type: "string", description: "Filename substring to search for", isRequired: true),
            ToolArgumentDescriptor(name: "folder", type: "string", description: "Optional specific folder to search within allowed folders", isRequired: false),
            ToolArgumentDescriptor(name: "extension", type: "string", description: "Optional file extension filter without dot (e.g. 'txt', 'swift')", isRequired: false)
        ]
    }
    
    public let validator: FolderAllowlistValidator
    
    public init(validator: FolderAllowlistValidator = FolderAllowlistValidator()) {
        self.validator = validator
    }
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let query = args["query"], !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ToolResult(success: false, message: "Missing required 'query' argument.")
        }
        
        let extFilter = args["extension"]?.trimmingCharacters(in: .whitespaces).lowercased()
        let searchDirectories: [String]
        
        if let specificFolder = args["folder"], !specificFolder.trimmingCharacters(in: .whitespaces).isEmpty {
            switch validator.validate(path: specificFolder) {
            case .success(let resolved):
                searchDirectories = [resolved]
            case .failure(let err):
                return ToolResult(success: false, message: "Specified folder error: \(err.localizedDescription)")
            }
        } else {
            searchDirectories = validator.allowedFolders.compactMap { folder in
                let exp = (folder as NSString).expandingTildeInPath
                let res = URL(fileURLWithPath: exp).resolvingSymlinksInPath().path
                return FileManager.default.fileExists(atPath: res) ? res : nil
            }
        }
        
        var matches: [String] = []
        let maxResults = 25
        let lowerQuery = query.lowercased()
        
        for dir in searchDirectories {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            
            while let fileURL = enumerator.nextObject() as? URL {
                if matches.count >= maxResults { break }
                
                let filePath = fileURL.resolvingSymlinksInPath().path
                // Skip sensitive paths during search
                if FolderAllowlistValidator.isNeverAllowed(path: filePath).blocked {
                    continue
                }
                
                let filename = fileURL.lastPathComponent
                if filename.lowercased().contains(lowerQuery) {
                    if let ext = extFilter, !ext.isEmpty {
                        guard fileURL.pathExtension.lowercased() == ext else { continue }
                    }
                    
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    matches.append("\(filePath) (\(size) bytes)")
                }
            }
            if matches.count >= maxResults { break }
        }
        
        if matches.isEmpty {
            return ToolResult(success: true, message: "No files found matching query '\(query)'.")
        }
        
        let formatted = "Found \(matches.count) file(s):\n" + matches.joined(separator: "\n")
        return ToolResult(success: true, message: formatted)
    }
}

// MARK: - ReadFileSafeTool

public final class ReadFileSafeTool: PearlTool {
    public let name = "read_file_safe"
    public let description = "Safely read up to 64 KB of a file within allowed folders via QuarantinedReader"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "path", type: "string", description: "Path to the file to read", isRequired: true)
        ]
    }
    
    public let validator: FolderAllowlistValidator
    
    public init(validator: FolderAllowlistValidator = FolderAllowlistValidator()) {
        self.validator = validator
    }
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let path = args["path"], !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ToolResult(success: false, message: "Missing required 'path' argument.")
        }
        
        let resolvedPath: String
        switch validator.validate(path: path) {
        case .success(let resolved):
            resolvedPath = resolved
        case .failure(let err):
            return ToolResult(success: false, message: "Access denied: \(err.localizedDescription)")
        }
        
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir) else {
            return ToolResult(success: false, message: "File does not exist: \(resolvedPath)")
        }
        if isDir.boolValue {
            return ToolResult(success: false, message: "Path is a directory, not a regular file: \(resolvedPath)")
        }
        
        guard let fileHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: resolvedPath)) else {
            return ToolResult(success: false, message: "Could not open file handle for reading: \(resolvedPath)")
        }
        defer { try? fileHandle.close() }
        
        // Read up to 64 KB
        let maxBytes = 64 * 1024
        let rawData = fileHandle.readData(ofLength: maxBytes)
        let rawContent = String(decoding: rawData, as: UTF8.self)
        
        // Quarantine external text and mark context as tainted
        let sanitized = await QuarantinedReader.shared.sanitize(untrustedText: rawContent, source: "file")
        TaintTracker.shared.markTainted(
            source: "file",
            reason: "Read safe file at \(resolvedPath) (\(rawData.count) bytes)"
        )
        
        return ToolResult(
            success: true,
            message: sanitized.summary,
            trust: .untrusted
        )
    }
}

// MARK: - CopyFileTool

public final class CopyFileTool: PearlTool {
    public let name = "copy_file"
    public let description = "Copy a file between allowed folders with undo support"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = []
    public let isReversible = true
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "source", type: "string", description: "Source file path", isRequired: true),
            ToolArgumentDescriptor(name: "destination", type: "string", description: "Destination file path", isRequired: true)
        ]
    }
    
    public let validator: FolderAllowlistValidator
    
    public init(validator: FolderAllowlistValidator = FolderAllowlistValidator()) {
        self.validator = validator
    }
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let src = args["source"], let dst = args["destination"] else {
            return ToolResult(success: false, message: "Missing required 'source' or 'destination' argument.")
        }
        
        let resolvedSrc: String
        switch validator.validate(path: src) {
        case .success(let s): resolvedSrc = s
        case .failure(let err): return ToolResult(success: false, message: "Source access denied: \(err.localizedDescription)")
        }
        
        let resolvedDst: String
        switch validator.validate(path: dst) {
        case .success(let d): resolvedDst = d
        case .failure(let err): return ToolResult(success: false, message: "Destination access denied: \(err.localizedDescription)")
        }
        
        guard FileManager.default.fileExists(atPath: resolvedSrc) else {
            return ToolResult(success: false, message: "Source file does not exist: \(resolvedSrc)")
        }
        if FileManager.default.fileExists(atPath: resolvedDst) {
            return ToolResult(success: false, message: "Destination file already exists: \(resolvedDst)")
        }
        
        do {
            try FileManager.default.copyItem(atPath: resolvedSrc, toPath: resolvedDst)
            
            let undoAction: @Sendable () async throws -> Void = {
                try? FileManager.default.removeItem(atPath: resolvedDst)
            }
            
            return ToolResult(
                success: true,
                message: "Copied '\(resolvedSrc)' to '\(resolvedDst)'.",
                undoAction: undoAction
            )
        } catch {
            return ToolResult(success: false, message: "Failed to copy file: \(error.localizedDescription)")
        }
    }
}

// MARK: - MoveFileTool

public final class MoveFileTool: PearlTool {
    public let name = "move_file"
    public let description = "Move a file between allowed folders with undo support (workspace change)"
    public let tier = ToolTier.t3WorkspaceChanges
    public let requiredTCC: [TCCService] = []
    public let isReversible = true
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "source", type: "string", description: "Source file path", isRequired: true),
            ToolArgumentDescriptor(name: "destination", type: "string", description: "Destination file path", isRequired: true)
        ]
    }
    
    public let validator: FolderAllowlistValidator
    
    public init(validator: FolderAllowlistValidator = FolderAllowlistValidator()) {
        self.validator = validator
    }
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let src = args["source"], let dst = args["destination"] else {
            return ToolResult(success: false, message: "Missing required 'source' or 'destination' argument.")
        }
        
        let resolvedSrc: String
        switch validator.validate(path: src) {
        case .success(let s): resolvedSrc = s
        case .failure(let err): return ToolResult(success: false, message: "Source access denied: \(err.localizedDescription)")
        }
        
        let resolvedDst: String
        switch validator.validate(path: dst) {
        case .success(let d): resolvedDst = d
        case .failure(let err): return ToolResult(success: false, message: "Destination access denied: \(err.localizedDescription)")
        }
        
        guard FileManager.default.fileExists(atPath: resolvedSrc) else {
            return ToolResult(success: false, message: "Source file does not exist: \(resolvedSrc)")
        }
        if FileManager.default.fileExists(atPath: resolvedDst) {
            return ToolResult(success: false, message: "Destination file already exists: \(resolvedDst)")
        }
        
        do {
            try FileManager.default.moveItem(atPath: resolvedSrc, toPath: resolvedDst)
            
            let undoAction: @Sendable () async throws -> Void = {
                try? FileManager.default.moveItem(atPath: resolvedDst, toPath: resolvedSrc)
            }
            
            return ToolResult(
                success: true,
                message: "Moved '\(resolvedSrc)' to '\(resolvedDst)'.",
                undoAction: undoAction
            )
        } catch {
            return ToolResult(success: false, message: "Failed to move file: \(error.localizedDescription)")
        }
    }
}
