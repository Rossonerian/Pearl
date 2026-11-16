import Foundation
import PearlCore

/// Errors that can occur during folder allowlist validation.
public enum FolderValidationError: Error, LocalizedError, Equatable, Sendable {
    case blockedByNeverTier(reason: String)
    case outsideAllowedFolders(path: String)
    case sensitivePathBlocked(path: String)
    case pathDoesNotExist(path: String)
    case emptyPath
    case relativePathNotSupported(String)
    case invalidPath(String)
    case pathTraversalBlocked(String)
    case permissionDenied(String)

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
        case .relativePathNotSupported(let path):
            return "Relative path '\(path)' is not supported. Provide an absolute path or a path starting with '~/'. "
        case .invalidPath(let path):
            return "Path '\(path)' is invalid or unsupported."
        case .pathTraversalBlocked(let path):
            return "Path '\(path)' contains disallowed '..' traversal segments."
        case .permissionDenied(let path):
            return "Permission denied for path '\(path)'."
        }
    }

    /// Maps a validation failure to the canonical `PearlToolErrorCode`.
    public var toolErrorCode: PearlToolErrorCode {
        switch self {
        case .emptyPath, .relativePathNotSupported, .invalidPath, .pathTraversalBlocked:
            return .invalidArguments
        case .outsideAllowedFolders:
            return .outsideApprovedFolders
        case .sensitivePathBlocked, .blockedByNeverTier, .permissionDenied:
            return .permissionDenied
        case .pathDoesNotExist:
            return .parentMissing
        }
    }
}

/// Enforces folder allowlisting, ancestral symlink resolution, and NeverTier sensitive path blocking.
public struct FolderAllowlistValidator: Sendable {
    public static let defaultAllowedFolders: [String] = [
        "~/Documents", "~/Downloads", "~/Desktop", "~/Projects"
    ]

    public static var sensitiveDirectories: [String] {
        return FilesystemPermissionManager.systemProtectedRoots + FilesystemPermissionManager.userSensitiveRoots
    }

    private let explicitAllowedFolders: [String]?
    private let permissionManager: FilesystemPermissionManager

    public var allowedFolders: [String] {
        return explicitAllowedFolders ?? permissionManager.approvedFolderPaths()
    }

    public var allowedRoots: [String] {
        return permissionManager.approvedFolderPaths()
    }

    public init(allowedFolders: [String]? = nil, permissionManager: FilesystemPermissionManager? = nil) {
        self.explicitAllowedFolders = allowedFolders
        if let explicit = allowedFolders {
            self.permissionManager = permissionManager ?? FilesystemPermissionManager(allowedFoldersOverride: explicit)
        } else {
            self.permissionManager = permissionManager ?? .shared
        }
    }

    /// Resolves a raw path ancestrally without checking allowlist boundaries.
    public func resolvePath(_ rawPath: String) throws -> String {
        return try permissionManager.normalizeAndResolvePath(rawPath)
    }

    /// Checks whether a given path violates hard security policies (NeverTier, sensitive directories, secrets).
    public static func isNeverAllowed(path: String) -> (blocked: Bool, reason: String?) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (false, nil) }

        let resolved = (try? FilesystemPermissionManager.normalizeAndResolvePathStatic(trimmed))
            ?? (trimmed as NSString).expandingTildeInPath
        let expanded = (try? FilesystemPermissionManager.normalizeWithoutSymlinkResolution(trimmed))
            ?? (trimmed as NSString).expandingTildeInPath

        if FilesystemPermissionManager.isSensitiveOrSystemPath(canonicalPath: resolved, rawPath: expanded) {
            return (true, "NeverTier: Path '\(resolved)' is recognized as a sensitive system or user location")
        }
        return (false, nil)
    }

    /// Resolves symlinks ancestrally and ensures the target resides strictly within an approved folder.
    public func validate(path: String, requireExisting: Bool = false) -> Result<String, FolderValidationError> {
        do {
            let resolved = try permissionManager.validateApprovedPath(path, requireExisting: requireExisting)
            return .success(resolved)
        } catch let error as FolderValidationError {
            return .failure(error)
        } catch {
            return .failure(.invalidPath(path))
        }
    }

    /// Validates that a path is within approved folders, exists on disk, and is a directory.
    public func validateDirectory(path: String) -> Result<String, FolderValidationError> {
        switch validate(path: path, requireExisting: true) {
        case .failure(let err):
            return .failure(err)
        case .success(let resolved):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
                return .failure(.invalidPath(resolved))
            }
            return .success(resolved)
        }
    }

    /// Returns true when the canonical path matches one of the configured approved folder roots.
    public func isApprovedRoot(_ resolvedPath: String) -> Bool {
        let lower = resolvedPath.lowercased()
        return allowedRoots.contains { $0.lowercased() == lower }
    }

    internal func containsResolvedPath(_ resolvedPath: String) -> Bool {
        return allowedRoots.contains { FilesystemPermissionManager.path(resolvedPath, isWithinRoot: $0) }
    }

    public static func validate(
        path: String,
        allowedFolders: [String]? = nil,
        requireExisting: Bool = false
    ) -> Result<String, FolderValidationError> {
        let validator = FolderAllowlistValidator(allowedFolders: allowedFolders)
        return validator.validate(path: path, requireExisting: requireExisting)
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
            ToolArgumentDescriptor(name: "query", type: "string", description: "Filename substring to search for", isRequired: false),
            ToolArgumentDescriptor(name: "folder", type: "string", description: "Optional specific folder to search within allowed folders", isRequired: false),
            ToolArgumentDescriptor(name: "extension", type: "string", description: "Optional file extension filter without dot (e.g. 'txt', 'swift')", isRequired: false)
        ]
    }

    public let validator: FolderAllowlistValidator

    public init(validator: FolderAllowlistValidator = FolderAllowlistValidator()) {
        self.validator = validator
    }

    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let rawQuery = (args["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawExt = (args["extension"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let extFilter = (rawExt.hasPrefix(".") ? String(rawExt.dropFirst()) : rawExt).lowercased()

        guard !rawQuery.isEmpty || !extFilter.isEmpty else {
            return ToolResult(
                success: false,
                message: "Provide a 'query' substring or an 'extension' filter to search for files.",
                errorCode: .invalidArguments
            )
        }

        let searchDirectories: [String]
        var canonicalTarget: String? = nil

        if let specificFolder = args["folder"]?.trimmingCharacters(in: .whitespacesAndNewlines), !specificFolder.isEmpty {
            switch validator.validateDirectory(path: specificFolder) {
            case .success(let resolved):
                searchDirectories = [resolved]
                canonicalTarget = resolved
            case .failure(let err):
                return ToolResult(
                    success: false,
                    message: "Specified folder error: \(err.localizedDescription)",
                    errorCode: err.toolErrorCode
                )
            }
        } else {
            searchDirectories = validator.allowedRoots.filter { root in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: root, isDirectory: &isDir) && isDir.boolValue
            }
        }

        var matches: [String] = []
        let maxResults = 25
        let lowerQuery = rawQuery.lowercased()

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
                if FolderAllowlistValidator.isNeverAllowed(path: filePath).blocked || !validator.containsResolvedPath(filePath) {
                    continue
                }

                let filename = fileURL.lastPathComponent
                let matchesQuery = lowerQuery.isEmpty || filename.lowercased().contains(lowerQuery)
                let matchesExt = extFilter.isEmpty || fileURL.pathExtension.lowercased() == extFilter

                if matchesQuery && matchesExt {
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    matches.append("\(filePath) (\(size) bytes)")
                }
            }
            if matches.count >= maxResults { break }
        }

        if matches.isEmpty {
            let criteria = !rawQuery.isEmpty ? "query '\(rawQuery)'" : ".\(extFilter) extension"
            return ToolResult(
                success: true,
                message: "No files found matching \(criteria).",
                errorCode: .completed,
                canonicalPath: canonicalTarget
            )
        }

        let formatted = "Found \(matches.count) file(s):\n" + matches.joined(separator: "\n")
        return ToolResult(
            success: true,
            message: formatted,
            errorCode: .completed,
            canonicalPath: canonicalTarget
        )
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
        guard let path = args["path"]?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return ToolResult(success: false, message: "Missing required 'path' argument.", errorCode: .invalidArguments)
        }

        let resolvedPath: String
        switch validator.validate(path: path) {
        case .success(let resolved):
            resolvedPath = resolved
        case .failure(let err):
            return ToolResult(
                success: false,
                message: "Access denied: \(err.localizedDescription)",
                errorCode: err.toolErrorCode
            )
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir) else {
            return ToolResult(
                success: false,
                message: "File does not exist: \(resolvedPath)",
                errorCode: .parentMissing,
                canonicalPath: resolvedPath
            )
        }
        if isDir.boolValue {
            return ToolResult(
                success: false,
                message: "Path is a directory, not a regular file: \(resolvedPath)",
                errorCode: .invalidArguments,
                canonicalPath: resolvedPath
            )
        }

        let fd = Darwin.open(resolvedPath, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            let err = errno
            let code: PearlToolErrorCode = (err == ELOOP || err == EACCES || err == EPERM) ? .permissionDenied : .parentMissing
            return ToolResult(
                success: false,
                message: "Could not open file for reading (errno \(err)): \(resolvedPath)",
                errorCode: code,
                canonicalPath: resolvedPath
            )
        }
        let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? fileHandle.close() }

        let maxBytes = 64 * 1024
        let rawData = fileHandle.readData(ofLength: maxBytes)
        let rawContent = String(decoding: rawData, as: UTF8.self)

        let sanitized = await QuarantinedReader.shared.sanitize(untrustedText: rawContent, source: "file")
        TaintTracker.shared.markTainted(
            source: "file",
            reason: "Read safe file at \(resolvedPath) (\(rawData.count) bytes)"
        )

        return ToolResult(
            success: true,
            message: sanitized.summary,
            trust: .untrusted,
            errorCode: .completed,
            canonicalPath: resolvedPath
        )
    }
}

// MARK: - Shared Transfer Helpers

private enum FileTransferHelper {
    struct ResolvedTransfer {
        let source: String
        let destination: String
    }

    enum TransferResolution {
        case resolved(ResolvedTransfer)
        case failure(ToolResult)
    }

    static func resolvePaths(
        args: [String: String],
        validator: FolderAllowlistValidator,
        allowCaseOnlyOverwrite: Bool,
        forbidMovingApprovedRoot: Bool
    ) -> TransferResolution {
        guard let rawSrc = args["source"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let rawDst = args["destination"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSrc.isEmpty, !rawDst.isEmpty else {
            return .failure(ToolResult(
                success: false,
                message: "Missing required 'source' or 'destination' argument.",
                errorCode: .invalidArguments
            ))
        }

        let resolvedSrc: String
        switch validator.validate(path: rawSrc) {
        case .success(let s):
            resolvedSrc = s
        case .failure(let err):
            return .failure(ToolResult(
                success: false,
                message: "Source access denied: \(err.localizedDescription)",
                errorCode: err.toolErrorCode
            ))
        }

        if forbidMovingApprovedRoot && validator.isApprovedRoot(resolvedSrc) {
            return .failure(ToolResult(
                success: false,
                message: "Refusing to move approved root directory '\(resolvedSrc)'.",
                errorCode: .permissionDenied,
                canonicalPath: resolvedSrc
            ))
        }

        let fm = FileManager.default
        guard PathProbe.entryExists(resolvedSrc) else {
            return .failure(ToolResult(
                success: false,
                message: "Source file does not exist: \(resolvedSrc)",
                errorCode: .parentMissing,
                canonicalPath: resolvedSrc
            ))
        }

        let initialDst: String
        switch validator.validate(path: rawDst) {
        case .success(let d):
            initialDst = d
        case .failure(let err):
            return .failure(ToolResult(
                success: false,
                message: "Destination access denied: \(err.localizedDescription)",
                errorCode: err.toolErrorCode
            ))
        }

        var dstIsDir: ObjCBool = false
        let finalDst: String
        if fm.fileExists(atPath: initialDst, isDirectory: &dstIsDir), dstIsDir.boolValue {
            let sourceName = (resolvedSrc as NSString).lastPathComponent
            let candidate = (initialDst as NSString).appendingPathComponent(sourceName)
            switch validator.validate(path: candidate) {
            case .success(let validatedChild):
                finalDst = validatedChild
            case .failure(let err):
                return .failure(ToolResult(
                    success: false,
                    message: "Destination access denied: \(err.localizedDescription)",
                    errorCode: err.toolErrorCode
                ))
            }
        } else if rawDst.hasSuffix("/") {
            return .failure(ToolResult(
                success: false,
                message: "Destination directory does not exist: \(initialDst)",
                errorCode: .parentMissing,
                canonicalPath: initialDst
            ))
        } else {
            finalDst = initialDst
        }

        if resolvedSrc == finalDst {
            return .failure(ToolResult(
                success: false,
                message: "Source and destination paths are identical: '\(finalDst)'.",
                errorCode: .alreadyExists,
                canonicalPath: finalDst
            ))
        }

        let isCaseOnlyRename = allowCaseOnlyOverwrite && (resolvedSrc.lowercased() == finalDst.lowercased())
        if !isCaseOnlyRename && PathProbe.entryExists(finalDst) {
            return .failure(ToolResult(
                success: false,
                message: "Destination already exists: \(finalDst)",
                errorCode: .alreadyExists,
                canonicalPath: finalDst
            ))
        }

        let destParent = (finalDst as NSString).deletingLastPathComponent
        var parentIsDir: ObjCBool = false
        guard fm.fileExists(atPath: destParent, isDirectory: &parentIsDir), parentIsDir.boolValue else {
            return .failure(ToolResult(
                success: false,
                message: "Destination parent directory does not exist: \(destParent)",
                errorCode: .parentMissing,
                canonicalPath: finalDst
            ))
        }

        return .resolved(ResolvedTransfer(source: resolvedSrc, destination: finalDst))
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
            ToolArgumentDescriptor(name: "destination", type: "string", description: "Destination file or folder path", isRequired: true)
        ]
    }

    public let validator: FolderAllowlistValidator

    public init(validator: FolderAllowlistValidator = FolderAllowlistValidator()) {
        self.validator = validator
    }

    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let transfer: FileTransferHelper.ResolvedTransfer
        switch FileTransferHelper.resolvePaths(
            args: args,
            validator: validator,
            allowCaseOnlyOverwrite: false,
            forbidMovingApprovedRoot: false
        ) {
        case .resolved(let resolved):
            transfer = resolved
        case .failure(let failureResult):
            return failureResult
        }

        let fm = FileManager.default
        do {
            try fm.copyItem(atPath: transfer.source, toPath: transfer.destination)

            guard PathProbe.entryExists(transfer.destination) else {
                return ToolResult(
                    success: false,
                    message: "Copy could not be verified at '\(transfer.destination)'.",
                    canonicalPath: transfer.destination
                )
            }

            let dstPath = transfer.destination
            let undoAction: @Sendable () async throws -> Void = {
                guard PathProbe.entryExists(dstPath) else { return }
                if PathProbe.isSymbolicLink(dstPath) {
                    unlink(dstPath)
                    return
                }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: dstPath, isDirectory: &isDir) {
                    if isDir.boolValue {
                        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dstPath)) ?? []
                        if !contents.isEmpty {
                            throw SafeUndoError.nonEmptyDirectory(dstPath)
                        }
                    }
                    try FileManager.default.removeItem(atPath: dstPath)
                }
            }

            return ToolResult(
                success: true,
                message: "Copied '\(transfer.source)' to '\(transfer.destination)'.",
                undoAction: undoAction,
                errorCode: .completed,
                canonicalPath: transfer.destination
            )
        } catch {
            return ToolResult(
                success: false,
                message: "Failed to copy file: \(error.localizedDescription)",
                errorCode: FileToolErrorMapper.mapErrorCode(error),
                canonicalPath: transfer.destination
            )
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
            ToolArgumentDescriptor(name: "destination", type: "string", description: "Destination file or folder path", isRequired: true),
            ToolArgumentDescriptor(name: "confirm", type: "string", description: "Pass 'true' to confirm moving file", isRequired: false)
        ]
    }

    public let validator: FolderAllowlistValidator

    public init(validator: FolderAllowlistValidator = FolderAllowlistValidator()) {
        self.validator = validator
    }

    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let transfer: FileTransferHelper.ResolvedTransfer
        switch FileTransferHelper.resolvePaths(
            args: args,
            validator: validator,
            allowCaseOnlyOverwrite: true,
            forbidMovingApprovedRoot: true
        ) {
        case .resolved(let resolved):
            transfer = resolved
        case .failure(let failureResult):
            return failureResult
        }

        let fm = FileManager.default
        do {
            try fm.moveItem(atPath: transfer.source, toPath: transfer.destination)

            let movedExists = PathProbe.entryExists(transfer.destination)
            let isCaseOnly = transfer.source.lowercased() == transfer.destination.lowercased()
            let sourceGone = isCaseOnly || !PathProbe.entryExists(transfer.source)

            guard movedExists && sourceGone else {
                return ToolResult(
                    success: false,
                    message: "Move operation could not be verified on disk at '\(transfer.destination)'.",
                    canonicalPath: transfer.destination
                )
            }

            let srcPath = transfer.source
            let dstPath = transfer.destination
            let undoAction: @Sendable () async throws -> Void = {
                let fileManager = FileManager.default
                guard PathProbe.entryExists(dstPath) else {
                    throw SafeUndoError.targetMissing(dstPath)
                }
                if srcPath.lowercased() != dstPath.lowercased() && PathProbe.entryExists(srcPath) {
                    throw SafeUndoError.destinationCollision(srcPath)
                }
                try fileManager.moveItem(atPath: dstPath, toPath: srcPath)
            }

            return ToolResult(
                success: true,
                message: "Moved '\(transfer.source)' to '\(transfer.destination)'.",
                undoAction: undoAction,
                errorCode: .completed,
                canonicalPath: transfer.destination
            )
        } catch {
            return ToolResult(
                success: false,
                message: "Failed to move file: \(error.localizedDescription)",
                errorCode: FileToolErrorMapper.mapErrorCode(error),
                canonicalPath: transfer.destination
            )
        }
    }
}
