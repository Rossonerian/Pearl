import Foundation
import PearlCore

// MARK: - TrashFileTool

/// Safely moves an approved file or folder to the macOS Trash with verification and reversible restore undo.
public final class TrashFileTool: PearlTool {
    public let name = "trash_file"
    public let description = "Safely move a file or folder to macOS Trash (reversible, confirmation required)"
    public let tier = ToolTier.t3WorkspaceChanges
    public let requiredTCC: [TCCService] = []
    public let isReversible = true

    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "path", type: "string", description: "Path of file or directory to move to Trash", isRequired: true),
            ToolArgumentDescriptor(name: "confirm", type: "string", description: "Pass 'true' to confirm moving target to Trash", isRequired: false)
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

        let home = NSHomeDirectory()
        let homeResolved = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        if validator.isApprovedRoot(canonical) || canonical == home || canonical == homeResolved || canonical == "/" {
            return ToolResult(
                success: false,
                message: "Refusing to trash protected root directory '\(canonical)'.",
                errorCode: .permissionDenied,
                canonicalPath: canonical
            )
        }

        guard PathProbe.entryExists(canonical) else {
            return ToolResult(
                success: false,
                message: "Target does not exist: '\(canonical)'.",
                errorCode: .parentMissing,
                canonicalPath: canonical
            )
        }

        let sourceURL = URL(fileURLWithPath: canonical)
        var resultingURL: NSURL?

        do {
            try FileManager.default.trashItem(at: sourceURL, resultingItemURL: &resultingURL)
        } catch {
            return ToolResult(
                success: false,
                message: "Failed to move '\(canonical)' to Trash: \(error.localizedDescription)",
                errorCode: FileToolErrorMapper.mapErrorCode(error),
                canonicalPath: canonical
            )
        }

        guard let trashedURL = resultingURL as URL? else {
            return ToolResult(
                success: false,
                message: "Trash operation did not return a resulting Trash URL for '\(canonical)'.",
                canonicalPath: canonical
            )
        }

        guard !PathProbe.entryExists(canonical) && PathProbe.entryExists(trashedURL.path) else {
            return ToolResult(
                success: false,
                message: "Trash operation could not be verified on disk for '\(canonical)'.",
                canonicalPath: canonical
            )
        }

        let originalPath = canonical
        let capturedTrashedURL = trashedURL
        let undoAction: @Sendable () async throws -> Void = {
            let fm = FileManager.default
            guard PathProbe.entryExists(capturedTrashedURL.path) else {
                throw SafeUndoError.targetMissing(capturedTrashedURL.path)
            }
            guard !PathProbe.entryExists(originalPath) else {
                throw SafeUndoError.destinationCollision(originalPath)
            }
            let parentDir = (originalPath as NSString).deletingLastPathComponent
            var parentIsDir: ObjCBool = false
            guard fm.fileExists(atPath: parentDir, isDirectory: &parentIsDir), parentIsDir.boolValue else {
                throw SafeUndoError.targetMissing(parentDir)
            }
            try fm.moveItem(at: capturedTrashedURL, to: URL(fileURLWithPath: originalPath))
        }

        return ToolResult(
            success: true,
            message: "Moved '\(canonical)' to Trash.",
            undoAction: undoAction,
            errorCode: .completed,
            canonicalPath: canonical
        )
    }
}

// MARK: - TrashScreenshotsTool

public final class TrashScreenshotsTool: PearlTool {
    public let name = "trash_screenshots"
    public let description = "Safely move recent screenshots from Pictures/Pearl and Desktop to the Trash"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = []
    public let isReversible = true

    public init() {}

    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let fm = FileManager.default
        let picturesDir = fm.urls(for: .picturesDirectory, in: .userDomainMask).first!
        let pearlScreensDir = picturesDir.appendingPathComponent("Pearl", isDirectory: true)
        let desktopDir = fm.urls(for: .desktopDirectory, in: .userDomainMask).first!

        var filesToTrash: [URL] = []

        for dir in [pearlScreensDir, desktopDir] {
            if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) {
                for fileURL in contents {
                    let name = fileURL.lastPathComponent
                    if (name.hasPrefix("Screenshot") || name.hasPrefix("Screen Shot")) && (name.hasSuffix(".png") || name.hasSuffix(".jpg")) {
                        filesToTrash.append(fileURL)
                    }
                }
            }
        }

        guard !filesToTrash.isEmpty else {
            return ToolResult(success: true, message: "No screenshots found to clean up.")
        }

        var trashedPairs: [(original: URL, trash: URL)] = []

        for file in filesToTrash {
            var resultingURL: NSURL?
            do {
                try fm.trashItem(at: file, resultingItemURL: &resultingURL)
                if let trashed = resultingURL as URL? {
                    trashedPairs.append((original: file, trash: trashed))
                }
            } catch {
                NSLog("[TrashTool] Failed to trash %@: %@", file.path, error.localizedDescription)
            }
        }

        let count = trashedPairs.count
        guard count > 0 else {
            return ToolResult(success: false, message: "Failed to move screenshots to Trash.")
        }

        let capturedPairs = trashedPairs
        let undoAction: @Sendable () async throws -> Void = {
            let fileManager = FileManager.default
            for pair in capturedPairs {
                try? fileManager.moveItem(at: pair.trash, to: pair.original)
            }
        }

        let s = count == 1 ? "" : "s"
        return ToolResult(
            success: true,
            message: "Moved \(count) screenshot\(s) to Trash.",
            undoAction: undoAction
        )
    }
}
