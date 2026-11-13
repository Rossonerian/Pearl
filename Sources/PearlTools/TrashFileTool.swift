import Foundation
import PearlCore

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
