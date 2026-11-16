import Foundation
import PearlCore

/// Represents a search result in the markdown vault.
public struct VaultSearchHit: Codable, Sendable, Equatable {
    public let file: String
    public let snippet: String
    
    public init(file: String, snippet: String) {
        self.file = file
        self.snippet = snippet
    }
}

/// Errors related to markdown vault operations.
public enum VaultError: Error, LocalizedError, Equatable {
    case invalidNoteName(String)
    case emptyContent
    case noteNotFound(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidNoteName(let name):
            return "Invalid note name: '\(name)'."
        case .emptyContent:
            return "Note content cannot be empty."
        case .noteNotFound(let name):
            return "Note not found: '\(name)'."
        }
    }
}

/// Manages an Obsidian-compatible markdown knowledge vault.
public final class VaultManager: @unchecked Sendable {
    public static let shared = VaultManager()
    
    /// Default vault location: ~/Documents/PearlVault
    public static var defaultVaultURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Documents/PearlVault", isDirectory: true)
    }
    
    public let vaultURL: URL
    private let lock = NSLock()
    
    public init(vaultURL: URL = VaultManager.defaultVaultURL) {
        self.vaultURL = vaultURL
        try? FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    }
    
    /// Resolves and sanitizes a relative note name safely.
    /// Prevents path traversal escapes (e.g. '..') and ensures the '.md' extension.
    public func resolveAndSanitize(name: String) throws -> (url: URL, relativePath: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VaultError.invalidNoteName(name)
        }
        
        // Block path traversal and absolute paths outside the vault
        if trimmed.contains("..") || trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            throw VaultError.invalidNoteName(name)
        }
        
        let pathWithExt = trimmed.hasSuffix(".md") ? trimmed : "\(trimmed).md"
        
        let canonicalVault = vaultURL.resolvingSymlinksInPath()
        let basePath = canonicalVault.path
        let resolvedURL = canonicalVault.appendingPathComponent(pathWithExt).standardizedFileURL
        let canonicalTarget = resolvedURL.resolvingSymlinksInPath()
        let resolvedPath = canonicalTarget.path
        
        guard resolvedPath.hasPrefix(basePath + "/") else {
            throw VaultError.invalidNoteName(name)
        }
        
        // Prevent symlink traversal out of vault
        var probe = resolvedURL
        while probe.path.hasPrefix(basePath) && probe.path != basePath {
            var statBuf = stat()
            if lstat(probe.path, &statBuf) == 0 {
                if (statBuf.st_mode & S_IFMT) == S_IFLNK {
                    throw VaultError.invalidNoteName("Symlinks within vault are forbidden: \(name)")
                }
            }
            probe = probe.deletingLastPathComponent()
        }
        
        let relativePath = String(resolvedPath.dropFirst(basePath.count + 1))
        return (canonicalTarget, relativePath)
    }
    
    /// Writes a note atomically (.tmp + rename) with YAML frontmatter and optional wikilinks section.
    @discardableResult
    public func writeNote(
        name: String,
        content: String,
        tags: [String] = ["agent-memory"],
        wikilinks: [String] = [],
        date: Date = Date()
    ) throws -> URL {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VaultError.emptyContent
        }
        
        let (resolvedURL, relativePath) = try resolveAndSanitize(name: name)
        
        let rawTitle = (name.hasSuffix(".md") ? String(name.dropLast(3)) : name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let noteTitle = rawTitle.isEmpty ? relativePath : rawTitle
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dateString = formatter.string(from: date)
        
        var frontmatter = "---\n"
        frontmatter += "title: \(noteTitle)\n"
        frontmatter += "date: \(dateString)\n"
        if tags.isEmpty {
            frontmatter += "tags: []\n"
        } else {
            frontmatter += "tags:\n"
            for tag in tags {
                frontmatter += "  - \(tag)\n"
            }
        }
        frontmatter += "---\n\n"
        
        var fullNote = frontmatter + content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !wikilinks.isEmpty {
            fullNote += "\n\n## Links\n"
            for link in wikilinks {
                let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]") {
                    fullNote += "- \(trimmed)\n"
                } else {
                    fullNote += "- [[\(trimmed)]]\n"
                }
            }
        } else {
            fullNote += "\n"
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        let parentDir = resolvedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        
        let tempURL = parentDir.appendingPathComponent(".\(resolvedURL.lastPathComponent).\(UUID().uuidString).tmp")
        try fullNote.write(to: tempURL, atomically: true, encoding: .utf8)
        
        if FileManager.default.fileExists(atPath: resolvedURL.path) {
            _ = try? FileManager.default.removeItem(at: resolvedURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: resolvedURL)
        
        return resolvedURL
    }
    
    /// Reads the raw text of a note if it exists.
    public func readNote(name: String) -> String? {
        guard let (resolvedURL, _) = try? resolveAndSanitize(name: name) else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }
        return try? String(contentsOf: resolvedURL, encoding: .utf8)
    }
    
    /// Lists all markdown notes in the vault, sorted by relative path.
    public func listNotes() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        
        let basePath = vaultURL.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        
        var notes: [String] = []
        while let fileURL = enumerator.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "md" else { continue }
            let resolved = fileURL.standardizedFileURL.path
            if resolved.hasPrefix(basePath + "/") {
                let relative = String(resolved.dropFirst(basePath.count + 1))
                notes.append(relative)
            }
        }
        return notes.sorted()
    }
    
    /// Searches case-insensitively across markdown filenames and contents.
    public func searchNotes(query: String) -> [VaultSearchHit] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        let lowerQuery = trimmedQuery.lowercased()
        
        let notes = listNotes()
        var hits: [VaultSearchHit] = []
        
        for relativePath in notes {
            guard let content = readNote(name: relativePath) else { continue }
            
            let filenameMatches = relativePath.lowercased().contains(lowerQuery)
            let contentMatches = content.lowercased().contains(lowerQuery)
            
            if contentMatches || filenameMatches {
                var bestSnippet: String = ""
                let lines = content.components(separatedBy: .newlines)
                for line in lines {
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                    if trimmedLine.lowercased().contains(lowerQuery) {
                        bestSnippet = trimmedLine
                        break
                    }
                }
                
                if bestSnippet.isEmpty {
                    bestSnippet = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? relativePath
                }
                
                hits.append(VaultSearchHit(file: relativePath, snippet: bestSnippet))
            }
        }
        
        return hits
    }
    
    /// Helper for bridging remembered facts into `Memory/Facts.md`.
    @discardableResult
    public func syncFactToVault(key: String, value: String) throws -> URL {
        let factsNoteName = "Memory/Facts.md"
        let factLine = "- **\(key)**: \(value)"
        
        let existingNote = readNote(name: factsNoteName)
        let updatedContent: String
        
        if let existing = existingNote, !existing.isEmpty {
            let body: String
            if existing.hasPrefix("---") {
                let parts = existing.components(separatedBy: "---")
                if parts.count >= 3 {
                    body = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    body = existing.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else {
                body = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            if body.contains(factLine) {
                updatedContent = body
            } else {
                updatedContent = body + "\n" + factLine
            }
        } else {
            updatedContent = "# Stored Facts\n\n" + factLine
        }
        
        return try writeNote(
            name: factsNoteName,
            content: updatedContent,
            tags: ["agent-memory", "facts"],
            wikilinks: []
        )
    }
}
