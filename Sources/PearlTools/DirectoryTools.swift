import Darwin
import Foundation
import PearlCore

// MARK: - CreateDirectoryTool

/// Creates a directory inside approved folders with verification and safe empty-only undo.
public final class CreateDirectoryTool: PearlTool {
    public let name = "create_directory"
    public let description = "Create a new folder at the specified approved path with verification and safe empty-only undo"
    public let tier = ToolTier.t3WorkspaceChanges
    public let requiredTCC: [TCCService] = []
    public let isReversible = true

    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "path",
                type: "string",
                description: "Absolute or user-relative target directory path (e.g. ~/Desktop/Pearl)",
                isRequired: true
            ),
            ToolArgumentDescriptor(
                name: "recursive",
                type: "string",
                description: "Create missing intermediate parent directories ('true'/'false')",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "create_if_missing",
                type: "string",
                description: "Idempotently succeed if directory already exists ('true'/'false')",
                isRequired: false
            )
        ]
    }

    public let validator: FolderAllowlistValidator

    public init(validator: FolderAllowlistValidator = FolderAllowlistValidator()) {
        self.validator = validator
    }

    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let rawPath = args["path"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            return ToolResult(
                success: false,
                message: "Missing required 'path' argument.",
                errorCode: .invalidArguments
            )
        }

        let recursive = args["recursive"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
        let createIfMissing = args["create_if_missing"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"

        let canonical: String
        switch validator.validate(path: rawPath) {
        case .success(let resolved):
            canonical = resolved
        case .failure(let err):
            return ToolResult(
                success: false,
                message: "Access denied: \(err.localizedDescription)",
                errorCode: err.toolErrorCode
            )
        }

        let fm = FileManager.default
        if PathProbe.isSymbolicLink(canonical) {
            return ToolResult(
                success: false,
                message: "A symbolic link already exists at '\(canonical)'.",
                errorCode: .alreadyExists,
                canonicalPath: canonical
            )
        }

        var existingIsDir: ObjCBool = false
        if fm.fileExists(atPath: canonical, isDirectory: &existingIsDir) {
            if !existingIsDir.boolValue {
                return ToolResult(
                    success: false,
                    message: "A file already exists at '\(canonical)'.",
                    errorCode: .alreadyExists,
                    canonicalPath: canonical
                )
            }
            if createIfMissing {
                guard fm.isReadableFile(atPath: canonical) else {
                    return ToolResult(
                        success: false,
                        message: "Directory exists at '\(canonical)' but is not readable.",
                        errorCode: .permissionDenied,
                        canonicalPath: canonical
                    )
                }
                return ToolResult(
                    success: true,
                    message: "Directory already exists at '\(canonical)'.",
                    errorCode: .completed,
                    canonicalPath: canonical
                )
            } else {
                return ToolResult(
                    success: false,
                    message: "Directory already exists at '\(canonical)'.",
                    errorCode: .alreadyExists,
                    canonicalPath: canonical
                )
            }
        }

        let parentPath = (canonical as NSString).deletingLastPathComponent
        var createdDirectoriesDeepestFirst: [String] = []

        if !recursive {
            var parentIsDir: ObjCBool = false
            guard fm.fileExists(atPath: parentPath, isDirectory: &parentIsDir), parentIsDir.boolValue else {
                return ToolResult(
                    success: false,
                    message: "Parent directory '\(parentPath)' does not exist.",
                    errorCode: .parentMissing,
                    canonicalPath: canonical
                )
            }
            guard fm.isWritableFile(atPath: parentPath) else {
                return ToolResult(
                    success: false,
                    message: "Permission denied: parent directory '\(parentPath)' is not writable.",
                    errorCode: .permissionDenied,
                    canonicalPath: canonical
                )
            }
            createdDirectoriesDeepestFirst = [canonical]
        } else {
            var probe = canonical
            var existingAncestor: String? = nil
            while probe != "/" && !probe.isEmpty {
                if PathProbe.entryExists(probe) {
                    existingAncestor = probe
                    break
                }
                createdDirectoriesDeepestFirst.append(probe)
                probe = (probe as NSString).deletingLastPathComponent
            }

            let ancestorToCheck = existingAncestor ?? "/"
            var ancestorIsDir: ObjCBool = false
            guard fm.fileExists(atPath: ancestorToCheck, isDirectory: &ancestorIsDir), ancestorIsDir.boolValue else {
                return ToolResult(
                    success: false,
                    message: "Cannot create directory: ancestor '\(ancestorToCheck)' is not a directory.",
                    errorCode: .alreadyExists,
                    canonicalPath: canonical
                )
            }
            guard fm.isWritableFile(atPath: ancestorToCheck) else {
                return ToolResult(
                    success: false,
                    message: "Permission denied: ancestor directory '\(ancestorToCheck)' is not writable.",
                    errorCode: .permissionDenied,
                    canonicalPath: canonical
                )
            }
        }

        do {
            try fm.createDirectory(atPath: canonical, withIntermediateDirectories: recursive, attributes: nil)
        } catch {
            return ToolResult(
                success: false,
                message: "Failed to create directory '\(canonical)': \(error.localizedDescription)",
                errorCode: FileToolErrorMapper.mapErrorCode(error),
                canonicalPath: canonical
            )
        }

        var verifyIsDir: ObjCBool = false
        guard fm.fileExists(atPath: canonical, isDirectory: &verifyIsDir), verifyIsDir.boolValue else {
            return ToolResult(
                success: false,
                message: "Directory creation could not be verified at '\(canonical)'.",
                canonicalPath: canonical
            )
        }

        let pathsToUndo = createdDirectoriesDeepestFirst
        let undoAction: @Sendable () async throws -> Void = {
            let fileManager = FileManager.default
            for dirPath in pathsToUndo {
                if PathProbe.isSymbolicLink(dirPath) {
                    throw SafeUndoError.unexpectedEntryType(dirPath)
                }
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: dirPath, isDirectory: &isDir) else {
                    continue
                }
                guard isDir.boolValue else {
                    throw SafeUndoError.unexpectedEntryType(dirPath)
                }
                let contents = try fileManager.contentsOfDirectory(atPath: dirPath)
                guard contents.isEmpty else {
                    throw SafeUndoError.nonEmptyDirectory(dirPath)
                }
                if rmdir(dirPath) != 0 {
                    throw SafeUndoError.removalFailed(dirPath, errno)
                }
            }
        }

        return ToolResult(
            success: true,
            message: "Created directory at '\(canonical)'.",
            undoAction: undoAction,
            errorCode: .completed,
            canonicalPath: canonical
        )
    }
}

// MARK: - ListDirectoryTool

/// Lists files and subdirectories inside an approved directory with sorting, filtering, and limit clamping.
public final class ListDirectoryTool: PearlTool {
    public let name = "list_directory"
    public let description = "List files and folders inside an approved directory with optional recursion, limit, and filtering"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false

    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "path", type: "string", description: "Target directory path (e.g. ~/Desktop)", isRequired: true),
            ToolArgumentDescriptor(name: "recursive", type: "string", description: "List subdirectories recursively ('true'/'false', default 'false')", isRequired: false),
            ToolArgumentDescriptor(name: "limit", type: "string", description: "Maximum number of entries to return (default 50, max 200)", isRequired: false),
            ToolArgumentDescriptor(name: "filter", type: "string", description: "Entry type or substring filter ('all', 'folders', 'files', or extension/substring)", isRequired: false)
        ]
    }

    public let validator: FolderAllowlistValidator

    public init(validator: FolderAllowlistValidator = FolderAllowlistValidator()) {
        self.validator = validator
    }

    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let rawPath = args["path"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            return ToolResult(
                success: false,
                message: "Missing required 'path' argument.",
                errorCode: .invalidArguments
            )
        }

        let recursive = args["recursive"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
        let requestedLimit = Int(args["limit"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 50
        let limit = min(max(requestedLimit, 1), 200)
        let rawFilter = (args["filter"] ?? "all").trimmingCharacters(in: .whitespacesAndNewlines)
        let filterLower = rawFilter.lowercased()

        let canonical: String
        switch validator.validate(path: rawPath) {
        case .success(let resolved):
            canonical = resolved
        case .failure(let err):
            return ToolResult(
                success: false,
                message: "Access denied: \(err.localizedDescription)",
                errorCode: err.toolErrorCode
            )
        }

        let homePath = NSHomeDirectory()
        let homeResolved = URL(fileURLWithPath: homePath).resolvingSymlinksInPath().path
        if recursive && (canonical == homePath || canonical == homeResolved || canonical == "/") {
            return ToolResult(
                success: false,
                message: "Recursive directory listing of the entire home or root directory is not permitted.",
                errorCode: .permissionDenied,
                canonicalPath: canonical
            )
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: canonical, isDirectory: &isDir) else {
            return ToolResult(
                success: false,
                message: "Directory does not exist: '\(canonical)'.",
                errorCode: .parentMissing,
                canonicalPath: canonical
            )
        }
        guard isDir.boolValue else {
            return ToolResult(
                success: false,
                message: "Path '\(canonical)' is a regular file, not a directory.",
                errorCode: .invalidArguments,
                canonicalPath: canonical
            )
        }

        let dirURL = URL(fileURLWithPath: canonical, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

        struct ListedEntry {
            let displayName: String
            let isDirectory: Bool
            let fileSize: Int
            let itemCount: Int?
            let modifiedDate: Date?
        }

        let itemURLs: [URL]
        if !recursive {
            do {
                itemURLs = try fm.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                )
            } catch {
                return ToolResult(
                    success: false,
                    message: "Failed to list directory '\(canonical)': \(error.localizedDescription)",
                    errorCode: FileToolErrorMapper.mapErrorCode(error) ?? .permissionDenied,
                    canonicalPath: canonical
                )
            }
        } else {
            guard fm.isReadableFile(atPath: canonical),
                  let enumerator = fm.enumerator(
                      at: dirURL,
                      includingPropertiesForKeys: keys,
                      options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  ) else {
                return ToolResult(
                    success: false,
                    message: "Permission denied: cannot enumerate '\(canonical)'.",
                    errorCode: .permissionDenied,
                    canonicalPath: canonical
                )
            }

            var collected: [URL] = []
            while let item = enumerator.nextObject() as? URL {
                let resolvedItem = item.resolvingSymlinksInPath().path
                if FolderAllowlistValidator.isNeverAllowed(path: resolvedItem).blocked || !validator.containsResolvedPath(resolvedItem) {
                    continue
                }
                collected.append(item)
            }
            itemURLs = collected
        }

        let basePrefix = canonical == "/" ? "/" : canonical + "/"
        var entries: [ListedEntry] = []

        for url in itemURLs {
            let resolvedItem = url.resolvingSymlinksInPath().path
            if FolderAllowlistValidator.isNeverAllowed(path: resolvedItem).blocked || !validator.containsResolvedPath(resolvedItem) {
                continue
            }

            let values = try? url.resourceValues(forKeys: Set(keys))
            let itemIsDir = values?.isDirectory ?? false
            let fullPath = url.path
            let relName: String
            if recursive && fullPath.hasPrefix(basePrefix) {
                relName = String(fullPath.dropFirst(basePrefix.count))
            } else {
                relName = url.lastPathComponent
            }

            let matchesFilter: Bool
            switch filterLower {
            case "", "all":
                matchesFilter = true
            case "folders", "folder", "directories", "directory", "dirs":
                matchesFilter = itemIsDir
            case "files", "file":
                matchesFilter = !itemIsDir
            default:
                let extTarget = filterLower.hasPrefix(".") ? String(filterLower.dropFirst()) : filterLower
                let matchesExt = !itemIsDir && url.pathExtension.lowercased() == extTarget
                let matchesSubstring = relName.lowercased().contains(filterLower)
                matchesFilter = matchesExt || matchesSubstring
            }

            guard matchesFilter else { continue }

            let childCount: Int?
            if itemIsDir && !recursive {
                childCount = (try? fm.contentsOfDirectory(atPath: url.path))?.count
            } else {
                childCount = nil
            }

            entries.append(ListedEntry(
                displayName: relName,
                isDirectory: itemIsDir,
                fileSize: values?.fileSize ?? 0,
                itemCount: childCount,
                modifiedDate: values?.contentModificationDate
            ))
        }

        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        if entries.isEmpty {
            let msg = (filterLower.isEmpty || filterLower == "all")
                ? "Directory '\(canonical)' is empty."
                : "No entries matching filter '\(rawFilter)' in '\(canonical)'."
            return ToolResult(
                success: true,
                message: msg,
                errorCode: .completed,
                canonicalPath: canonical
            )
        }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"

        let shown = entries.prefix(limit)
        let formattedLines = shown.map { entry -> String in
            let modText = entry.modifiedDate.map { "modified \(df.string(from: $0))" } ?? "modified unknown"
            if entry.isDirectory {
                if let count = entry.itemCount {
                    return "[DIR] \(entry.displayName)/ (\(count) items, \(modText))"
                }
                return "[DIR] \(entry.displayName)/ (\(modText))"
            } else {
                return "[FILE] \(entry.displayName) (\(entry.fileSize) bytes, \(modText))"
            }
        }

        var output = "Contents of '\(canonical)' (\(entries.count) item(s)):\n" + formattedLines.joined(separator: "\n")
        if entries.count > limit {
            output += "\n... truncated (showing \(limit) of \(entries.count) items)."
        }

        return ToolResult(
            success: true,
            message: output,
            errorCode: .completed,
            canonicalPath: canonical
        )
    }
}

// MARK: - RenameFileTool

/// Renames a file or folder inside approved directories with collision checks and reversible undo.
public final class RenameFileTool: PearlTool {
    public let name = "rename_file"
    public let description = "Rename a file or folder within approved directories with collision detection and undo support"
    public let tier = ToolTier.t3WorkspaceChanges
    public let requiredTCC: [TCCService] = []
    public let isReversible = true

    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "source", type: "string", description: "Existing file or directory path", isRequired: true),
            ToolArgumentDescriptor(name: "destination", type: "string", description: "New path or new name in same parent directory", isRequired: true),
            ToolArgumentDescriptor(name: "confirm", type: "string", description: "Pass 'true' to confirm rename", isRequired: false)
        ]
    }

    public let validator: FolderAllowlistValidator

    public init(validator: FolderAllowlistValidator = FolderAllowlistValidator()) {
        self.validator = validator
    }

    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let rawSource = args["source"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let rawDest = args["destination"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSource.isEmpty, !rawDest.isEmpty else {
            return ToolResult(
                success: false,
                message: "Missing required 'source' or 'destination' argument.",
                errorCode: .invalidArguments
            )
        }

        let resolvedSource: String
        switch validator.validate(path: rawSource) {
        case .success(let s):
            resolvedSource = s
        case .failure(let err):
            return ToolResult(
                success: false,
                message: "Source access denied: \(err.localizedDescription)",
                errorCode: err.toolErrorCode
            )
        }

        if validator.isApprovedRoot(resolvedSource) {
            return ToolResult(
                success: false,
                message: "Refusing to rename protected approved root directory '\(resolvedSource)'.",
                errorCode: .permissionDenied,
                canonicalPath: resolvedSource
            )
        }

        guard PathProbe.entryExists(resolvedSource) else {
            return ToolResult(
                success: false,
                message: "Source does not exist: '\(resolvedSource)'.",
                errorCode: .parentMissing,
                canonicalPath: resolvedSource
            )
        }

        let candidateDestination: String
        if !rawDest.contains("/") && !rawDest.hasPrefix("~") {
            if rawDest.unicodeScalars.contains(where: { $0.value == 0 || CharacterSet.controlCharacters.contains($0) }) ||
               rawDest.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil ||
               rawDest == "." || rawDest == ".." {
                return ToolResult(
                    success: false,
                    message: "Invalid destination filename '\(rawDest)'.",
                    errorCode: .invalidArguments
                )
            }
            let parent = (resolvedSource as NSString).deletingLastPathComponent
            candidateDestination = (parent as NSString).appendingPathComponent(rawDest)
        } else {
            candidateDestination = rawDest
        }

        let resolvedDest: String
        switch validator.validate(path: candidateDestination) {
        case .success(let d):
            resolvedDest = d
        case .failure(let err):
            return ToolResult(
                success: false,
                message: "Destination access denied: \(err.localizedDescription)",
                errorCode: err.toolErrorCode
            )
        }

        if resolvedSource == resolvedDest {
            return ToolResult(
                success: false,
                message: "Source and destination are identical: '\(resolvedDest)'.",
                errorCode: .alreadyExists,
                canonicalPath: resolvedDest
            )
        }

        let isCaseOnlyRename = (resolvedSource.lowercased() == resolvedDest.lowercased())
        if !isCaseOnlyRename && PathProbe.entryExists(resolvedDest) {
            return ToolResult(
                success: false,
                message: "Destination already exists: '\(resolvedDest)'.",
                errorCode: .alreadyExists,
                canonicalPath: resolvedDest
            )
        }

        let fm = FileManager.default
        let destParent = (resolvedDest as NSString).deletingLastPathComponent
        var parentIsDir: ObjCBool = false
        guard fm.fileExists(atPath: destParent, isDirectory: &parentIsDir), parentIsDir.boolValue else {
            return ToolResult(
                success: false,
                message: "Destination parent directory does not exist: '\(destParent)'.",
                errorCode: .parentMissing,
                canonicalPath: resolvedDest
            )
        }

        do {
            try fm.moveItem(atPath: resolvedSource, toPath: resolvedDest)
        } catch {
            return ToolResult(
                success: false,
                message: "Failed to rename '\(resolvedSource)' to '\(resolvedDest)': \(error.localizedDescription)",
                errorCode: FileToolErrorMapper.mapErrorCode(error),
                canonicalPath: resolvedDest
            )
        }

        let destExists = PathProbe.entryExists(resolvedDest)
        let sourceGone = isCaseOnlyRename || !PathProbe.entryExists(resolvedSource)
        guard destExists && sourceGone else {
            return ToolResult(
                success: false,
                message: "Rename could not be verified on disk at '\(resolvedDest)'.",
                canonicalPath: resolvedDest
            )
        }

        let undoAction: @Sendable () async throws -> Void = {
            let fileManager = FileManager.default
            guard PathProbe.entryExists(resolvedDest) else {
                throw SafeUndoError.targetMissing(resolvedDest)
            }
            if !isCaseOnlyRename && PathProbe.entryExists(resolvedSource) {
                throw SafeUndoError.destinationCollision(resolvedSource)
            }
            try fileManager.moveItem(atPath: resolvedDest, toPath: resolvedSource)
        }

        return ToolResult(
            success: true,
            message: "Renamed '\(resolvedSource)' to '\(resolvedDest)'.",
            undoAction: undoAction,
            errorCode: .completed,
            canonicalPath: resolvedDest
        )
    }
}
