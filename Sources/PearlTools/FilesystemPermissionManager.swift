#if canImport(AppKit)
import AppKit
#endif
import Darwin
import Foundation
import PearlCore

/// Live accessibility status for an approved filesystem root.
public enum FolderAccessStatus: String, Codable, Sendable, Equatable {
    case accessible
    case missing
    case needsAuthorization
    case bookmarkStale
}

/// Snapshot describing an approved folder, its canonical path, bookmark status, and live access state.
public struct ApprovedFolderEntry: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let displayPath: String
    public let canonicalPath: String
    public let status: FolderAccessStatus
    public let hasSecurityScopedBookmark: Bool
    public let isDefault: Bool

    public init(
        id: String,
        displayPath: String,
        canonicalPath: String,
        status: FolderAccessStatus,
        hasSecurityScopedBookmark: Bool,
        isDefault: Bool
    ) {
        self.id = id
        self.displayPath = displayPath
        self.canonicalPath = canonicalPath
        self.status = status
        self.hasSecurityScopedBookmark = hasSecurityScopedBookmark
        self.isDefault = isDefault
    }
}

/// Low-level POSIX `lstat` probes that do not follow terminal symlinks.
internal enum PathProbe {
    static func lstatInfo(at path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    static func entryExists(_ path: String) -> Bool {
        return FileManager.default.fileExists(atPath: path) || lstatInfo(at: path) != nil
    }

    static func isSymbolicLink(_ path: String) -> Bool {
        guard let st = lstatInfo(at: path) else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }
}

/// Errors thrown by safe undo closures when disk state has diverged since tool execution.
public enum SafeUndoError: Error, LocalizedError, Sendable {
    case nonEmptyDirectory(String)
    case unexpectedEntryType(String)
    case targetMissing(String)
    case destinationCollision(String)
    case removalFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .nonEmptyDirectory(let path):
            return "Refusing to undo directory creation: '\(path)' is no longer empty."
        case .unexpectedEntryType(let path):
            return "Refusing to undo: '\(path)' is no longer a regular directory."
        case .targetMissing(let path):
            return "Cannot undo: expected item at '\(path)' no longer exists."
        case .destinationCollision(let path):
            return "Cannot undo: destination '\(path)' already exists."
        case .removalFailed(let path, let code):
            return "Failed to remove empty directory '\(path)' (errno \(code))."
        }
    }
}

/// Maps POSIX / Cocoa filesystem errors into canonical `PearlToolErrorCode` values.
internal enum FileToolErrorMapper {
    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileReadNoPermissionError ||
               nsError.code == NSFileWriteNoPermissionError ||
               nsError.code == NSFileWriteVolumeReadOnlyError {
                return true
            }
        } else if nsError.domain == NSPOSIXErrorDomain {
            if nsError.code == Int(EACCES) || nsError.code == Int(EPERM) || nsError.code == Int(EROFS) {
                return true
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionError(underlying)
        }
        return false
    }

    static func mapErrorCode(_ error: Error) -> PearlToolErrorCode? {
        if isPermissionError(error) {
            return .permissionDenied
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileWriteFileExistsError {
                return .alreadyExists
            }
            if nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError {
                return .parentMissing
            }
        } else if nsError.domain == NSPOSIXErrorDomain {
            if nsError.code == Int(EEXIST) {
                return .alreadyExists
            }
            if nsError.code == Int(ENOENT) {
                return .parentMissing
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return mapErrorCode(underlying)
        }
        return nil
    }
}

/// Manages approved filesystem roots, ancestral symlink resolution, sensitive path blocking,
/// and security-scoped bookmark persistence (`folder_bookmarks.json`).
public final class FilesystemPermissionManager: @unchecked Sendable {
    public static let shared = FilesystemPermissionManager()

    public static let defaultApprovedFolders: [String] = [
        "~/Desktop", "~/Documents", "~/Downloads", "~/Projects"
    ]

    /// System and credential paths that are always denied regardless of allowlist configuration.
    public static let systemProtectedRoots: [String] = [
        "/System",
        "/Library",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/private/etc",
        "/var/db",
        "/private/var/db",
        "/var/root",
        "/private/var/root",
        "/dev"
    ]

    public static let userSensitiveRoots: [String] = [
        "~/.ssh",
        "~/.gnupg",
        "~/.aws",
        "~/.kube",
        "~/Library/Keychains",
        "~/Library/LaunchAgents",
        "~/Library/LaunchDaemons",
        "~/Library/Application Support/Pearl"
    ]

    private struct StoredBookmarkRecord: Codable, Sendable {
        let canonicalPath: String
        let displayPath: String
        let bookmarkData: Data?
        let isSecurityScoped: Bool
        let addedAt: Date
    }

    private let lock = NSLock()
    private let bookmarksFileURL: URL
    private let hasAllowedFoldersOverride: Bool
    private var config: PearlConfig
    private var configuredFolders: [String]
    private var bookmarks: [String: StoredBookmarkRecord] = [:]
    private var activeSecurityScopedURLs: [String: URL] = [:]

    public init(
        config: PearlConfig? = nil,
        bookmarksFileURL: URL? = nil,
        allowedFoldersOverride: [String]? = nil
    ) {
        self.bookmarksFileURL = bookmarksFileURL ?? PearlStoragePaths.fileURL(named: "folder_bookmarks.json")
        self.hasAllowedFoldersOverride = (allowedFoldersOverride != nil)

        if let override = allowedFoldersOverride {
            self.config = config ?? PearlConfig()
            self.configuredFolders = override
            if bookmarksFileURL != nil {
                self.bookmarks = Self.loadBookmarks(from: self.bookmarksFileURL)
            }
        } else {
            let loadedConfig = config ?? PearlConfig.load()
            self.config = loadedConfig
            self.bookmarks = Self.loadBookmarks(from: self.bookmarksFileURL)

            var merged = loadedConfig.allowedFolders
            var seenCanonical = Set(merged.compactMap { try? Self.normalizeAndResolvePathStatic($0) })
            for record in self.bookmarks.values.sorted(by: { $0.addedAt < $1.addedAt }) {
                if !seenCanonical.contains(record.canonicalPath),
                   !Self.isSensitiveOrSystemPath(canonicalPath: record.canonicalPath, rawPath: record.displayPath) {
                    merged.append(record.displayPath)
                    seenCanonical.insert(record.canonicalPath)
                }
            }
            self.configuredFolders = merged
        }
    }

    deinit {
        lock.lock()
        let active = Array(activeSecurityScopedURLs.values)
        activeSecurityScopedURLs.removeAll()
        lock.unlock()
        for url in active {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Path Normalization & Ancestral Symlink Resolution

    /// Normalizes a user-supplied path, rejects relative/traversal/scheme/control inputs,
    /// and resolves symlinks from the deepest existing ancestor downward.
    public func normalizeAndResolvePath(_ rawPath: String) throws -> String {
        return try Self.normalizeAndResolvePathStatic(rawPath)
    }

    internal static func normalizeWithoutSymlinkResolution(_ rawPath: String) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FolderValidationError.emptyPath
        }

        if trimmed.unicodeScalars.contains(where: { $0.value == 0 || CharacterSet.controlCharacters.contains($0) }) {
            throw FolderValidationError.invalidPath(rawPath)
        }

        if trimmed.contains("://") {
            throw FolderValidationError.invalidPath(rawPath)
        }

        if !trimmed.hasPrefix("/") && !trimmed.hasPrefix("~") {
            if trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil {
                throw FolderValidationError.invalidPath(rawPath)
            }
            let rawComponents = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            if rawComponents.contains("..") {
                throw FolderValidationError.pathTraversalBlocked(rawPath)
            }
            throw FolderValidationError.relativePathNotSupported(rawPath)
        }

        let rawComponents = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        if rawComponents.contains("..") {
            throw FolderValidationError.pathTraversalBlocked(rawPath)
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw FolderValidationError.invalidPath(rawPath)
        }

        let cleanComponents = expanded
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }

        if cleanComponents.contains("..") {
            throw FolderValidationError.pathTraversalBlocked(rawPath)
        }

        return cleanComponents.isEmpty ? "/" : "/" + cleanComponents.joined(separator: "/")
    }

    internal static func normalizeAndResolvePathStatic(_ rawPath: String) throws -> String {
        let normalized = try normalizeWithoutSymlinkResolution(rawPath)
        return try resolveAncestors(of: normalized, depth: 0)
    }

    private static func resolveAncestors(of normalizedPath: String, depth: Int) throws -> String {
        guard depth < 32 else {
            throw FolderValidationError.invalidPath(normalizedPath)
        }

        let parts = normalizedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else {
            return "/"
        }

        for count in stride(from: parts.count, through: 1, by: -1) {
            let candidate = "/" + parts[0..<count].joined(separator: "/")
            if let st = PathProbe.lstatInfo(at: candidate) {
                let trailing = Array(parts[count...])
                let resolvedAncestor: String

                if (st.st_mode & S_IFMT) == S_IFLNK && !FileManager.default.fileExists(atPath: candidate) {
                    let linkDest = try FileManager.default.destinationOfSymbolicLink(atPath: candidate)
                    let combined: String
                    if linkDest.hasPrefix("/") {
                        combined = linkDest
                    } else {
                        let parent = (candidate as NSString).deletingLastPathComponent
                        combined = (parent as NSString).appendingPathComponent(linkDest)
                    }
                    let standardizedTarget = (combined as NSString).standardizingPath
                    resolvedAncestor = try resolveAncestors(of: standardizedTarget, depth: depth + 1)
                } else {
                    resolvedAncestor = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
                }

                if trailing.isEmpty {
                    return resolvedAncestor
                }
                let base = resolvedAncestor == "/" ? "" : resolvedAncestor
                return base + "/" + trailing.joined(separator: "/")
            }
        }

        return normalizedPath
    }

    // MARK: - Sensitive Path & Allowlist Validation

    /// Evaluates whether a path targets a system-protected root, credential directory, or NeverTier location.
    public static func isSensitiveOrSystemPath(canonicalPath: String, rawPath: String? = nil) -> Bool {
        let candidates = [canonicalPath, rawPath].compactMap { $0 }

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let expanded = (trimmed as NSString).expandingTildeInPath
            let lower = expanded.lowercased()

            if NeverTierValidator.validate(command: expanded).isDenied {
                return true
            }
            if SeatbeltProfile.isSensitivePath(expanded) {
                return true
            }

            for root in systemProtectedRoots {
                let lowerRoot = root.lowercased()
                if lower == lowerRoot || lower.hasPrefix(lowerRoot + "/") {
                    return true
                }
                let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path.lowercased()
                if lower == resolvedRoot || lower.hasPrefix(resolvedRoot + "/") {
                    return true
                }
            }

            for userRoot in userSensitiveRoots {
                let expRoot = (userRoot as NSString).expandingTildeInPath
                let lowerExp = expRoot.lowercased()
                if lower == lowerExp || lower.hasPrefix(lowerExp + "/") {
                    return true
                }
                let resRoot = URL(fileURLWithPath: expRoot).resolvingSymlinksInPath().path.lowercased()
                if lower == resRoot || lower.hasPrefix(resRoot + "/") {
                    return true
                }
            }

            let fileName = (expanded as NSString).lastPathComponent.lowercased()
            if fileName == ".env" || fileName.hasPrefix(".env.") ||
               fileName.hasSuffix(".keychain") || fileName.hasSuffix(".keychain-db") {
                return true
            }
        }

        return false
    }

    /// Validates a path against NeverTier/sensitive rules and configured approved folder boundaries.
    public func validateApprovedPath(_ rawPath: String, requireExisting: Bool = false) throws -> String {
        let expandedWithoutLinks = try Self.normalizeWithoutSymlinkResolution(rawPath)
        let resolved = try Self.normalizeAndResolvePathStatic(rawPath)

        if Self.isSensitiveOrSystemPath(canonicalPath: resolved, rawPath: expandedWithoutLinks) {
            throw FolderValidationError.sensitivePathBlocked(path: resolved)
        }

        let roots = approvedFolderPaths()
        var matchedRoot: String? = nil
        for root in roots {
            if Self.path(resolved, isWithinRoot: root) {
                matchedRoot = root
                break
            }
        }

        guard let approvedRoot = matchedRoot else {
            throw FolderValidationError.outsideAllowedFolders(path: resolved)
        }

        _ = activateSecurityScopeIfNeeded(for: approvedRoot)

        if requireExisting && !PathProbe.entryExists(resolved) {
            throw FolderValidationError.pathDoesNotExist(path: resolved)
        }

        return resolved
    }

    internal static func path(_ candidate: String, isWithinRoot root: String) -> Bool {
        if root == "/" {
            return candidate.hasPrefix("/")
        }
        let lowerCandidate = candidate.lowercased()
        let lowerRoot = root.lowercased()
        return lowerCandidate == lowerRoot || lowerCandidate.hasPrefix(lowerRoot + "/")
    }

    // MARK: - Approved Folder Management & Bookmarks

    public func approvedFolderPaths() -> [String] {
        lock.lock()
        let folders = configuredFolders
        lock.unlock()

        var seen = Set<String>()
        var resolvedPaths: [String] = []
        for folder in folders {
            if let canonical = try? Self.normalizeAndResolvePathStatic(folder), !seen.contains(canonical) {
                seen.insert(canonical)
                resolvedPaths.append(canonical)
            }
        }
        return resolvedPaths
    }

    public func approvedFolderEntries() -> [ApprovedFolderEntry] {
        return evaluateFolderEntries(refreshBookmarks: false)
    }

    @discardableResult
    public func revalidateBookmarks() -> [ApprovedFolderEntry] {
        return evaluateFolderEntries(refreshBookmarks: true)
    }

    @discardableResult
    public func addApprovedFolder(url: URL, saveBookmark: Bool = true) throws -> ApprovedFolderEntry {
        guard url.isFileURL else {
            throw FolderValidationError.invalidPath(url.absoluteString)
        }

        let canonical = try Self.normalizeAndResolvePathStatic(url.path)
        try validateNewApprovedRoot(canonical, rawPath: url.path)

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: canonical, isDirectory: &isDir), !isDir.boolValue {
            throw FolderValidationError.invalidPath(canonical)
        }

        var bookmarkData: Data? = nil
        var isSecurityScoped = false
        if saveBookmark && FileManager.default.fileExists(atPath: canonical) {
            let targetURL = URL(fileURLWithPath: canonical, isDirectory: true)
            if let scoped = try? targetURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                bookmarkData = scoped
                isSecurityScoped = true
            } else if let standard = try? targetURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                bookmarkData = standard
                isSecurityScoped = false
            }
        }

        let display = Self.displayPath(for: canonical)
        let record = StoredBookmarkRecord(
            canonicalPath: canonical,
            displayPath: display,
            bookmarkData: bookmarkData,
            isSecurityScoped: isSecurityScoped,
            addedAt: Date()
        )

        lock.lock()
        if bookmarkData != nil {
            bookmarks[canonical] = record
        } else if !saveBookmark {
            bookmarks.removeValue(forKey: canonical)
        }
        if !configuredFolders.contains(where: { (try? Self.normalizeAndResolvePathStatic($0)) == canonical }) {
            configuredFolders.append(display)
        }
        let persistedBookmarks = bookmarks
        let updatedFolders = configuredFolders
        let shouldSyncConfig = !hasAllowedFoldersOverride
        var cfg = config
        cfg.allowedFolders = updatedFolders
        config = cfg
        lock.unlock()

        if bookmarkData != nil || FileManager.default.fileExists(atPath: bookmarksFileURL.path) {
            Self.saveBookmarks(persistedBookmarks, to: bookmarksFileURL)
        }
        if shouldSyncConfig {
            var diskConfig = PearlConfig.load()
            diskConfig.allowedFolders = updatedFolders
            diskConfig.save()
        }

        return buildEntry(forCanonicalPath: canonical, record: bookmarkData != nil ? record : nil, refreshBookmark: false)
    }

    @discardableResult
    public func addApprovedFolder(path: String) throws -> ApprovedFolderEntry {
        let canonical = try Self.normalizeAndResolvePathStatic(path)
        return try addApprovedFolder(url: URL(fileURLWithPath: canonical, isDirectory: true), saveBookmark: true)
    }

    public func removeApprovedFolder(path: String) {
        let canonical = (try? Self.normalizeAndResolvePathStatic(path)) ?? (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath

        lock.lock()
        if let activeURL = activeSecurityScopedURLs.removeValue(forKey: canonical) {
            activeURL.stopAccessingSecurityScopedResource()
        }
        bookmarks.removeValue(forKey: canonical)
        configuredFolders.removeAll { entry in
            if let entryCanon = try? Self.normalizeAndResolvePathStatic(entry) {
                return entryCanon == canonical
            }
            return entry == path
        }
        let persistedBookmarks = bookmarks
        let updatedFolders = configuredFolders
        let shouldSyncConfig = !hasAllowedFoldersOverride
        var cfg = config
        cfg.allowedFolders = updatedFolders
        config = cfg
        lock.unlock()

        Self.saveBookmarks(persistedBookmarks, to: bookmarksFileURL)
        if shouldSyncConfig {
            var diskConfig = PearlConfig.load()
            diskConfig.allowedFolders = updatedFolders
            diskConfig.save()
        }
    }

    #if canImport(AppKit)
    @MainActor
    public func promptUserToAuthorizeFolder(suggestedURL: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Authorize Folder"
        panel.message = "Select a folder to grant Pearl read/write access."
        if let suggested = suggestedURL {
            panel.directoryURL = suggested
        }
        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }
        guard (try? addApprovedFolder(url: selectedURL, saveBookmark: true)) != nil else {
            return nil
        }
        return selectedURL
    }
    #endif

    // MARK: - Internal Helpers

    private func validateNewApprovedRoot(_ canonical: String, rawPath: String) throws {
        if canonical == "/" || canonical == "/private" || canonical == "/var" {
            throw FolderValidationError.sensitivePathBlocked(path: canonical)
        }
        if Self.isSensitiveOrSystemPath(canonicalPath: canonical, rawPath: rawPath) {
            throw FolderValidationError.sensitivePathBlocked(path: canonical)
        }
    }

    private func evaluateFolderEntries(refreshBookmarks: Bool) -> [ApprovedFolderEntry] {
        let paths = approvedFolderPaths()
        lock.lock()
        let snapshot = bookmarks
        lock.unlock()

        return paths.map { canonical in
            buildEntry(forCanonicalPath: canonical, record: snapshot[canonical], refreshBookmark: refreshBookmarks)
        }
    }

    private func buildEntry(
        forCanonicalPath canonical: String,
        record: StoredBookmarkRecord?,
        refreshBookmark: Bool
    ) -> ApprovedFolderEntry {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: canonical, isDirectory: &isDir) && isDir.boolValue

        let status: FolderAccessStatus
        if !exists {
            status = .missing
        } else if let record = record, let data = record.bookmarkData {
            let resolution = resolveBookmark(data: data, isSecurityScoped: record.isSecurityScoped, canonicalPath: canonical, activateAccess: refreshBookmark)
            if resolution.isStale || !resolution.resolvedSuccessfully {
                status = .bookmarkStale
            } else if !fm.isReadableFile(atPath: canonical) {
                status = .needsAuthorization
            } else {
                status = .accessible
            }
        } else if !fm.isReadableFile(atPath: canonical) {
            status = .needsAuthorization
        } else {
            status = .accessible
        }

        return ApprovedFolderEntry(
            id: canonical,
            displayPath: record?.displayPath ?? Self.displayPath(for: canonical),
            canonicalPath: canonical,
            status: status,
            hasSecurityScopedBookmark: record?.bookmarkData != nil,
            isDefault: Self.isDefaultFolder(canonical)
        )
    }

    @discardableResult
    public func activateSecurityScopeIfNeeded(for canonicalRoot: String) -> Bool {
        lock.lock()
        if activeSecurityScopedURLs[canonicalRoot] != nil {
            lock.unlock()
            return true
        }
        let record = bookmarks[canonicalRoot]
        lock.unlock()

        guard let record = record, let data = record.bookmarkData else {
            return false
        }
        let resolution = resolveBookmark(
            data: data,
            isSecurityScoped: record.isSecurityScoped,
            canonicalPath: canonicalRoot,
            activateAccess: true
        )
        return resolution.resolvedSuccessfully && !resolution.isStale
    }

    private func resolveBookmark(
        data: Data,
        isSecurityScoped: Bool,
        canonicalPath: String,
        activateAccess: Bool
    ) -> (resolvedSuccessfully: Bool, isStale: Bool) {
        var isStale = false
        let options: URL.BookmarkResolutionOptions = isSecurityScoped ? [.withSecurityScope] : []
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if activateAccess && isSecurityScoped && !isStale {
                lock.lock()
                let alreadyActive = activeSecurityScopedURLs[canonicalPath] != nil
                lock.unlock()
                if !alreadyActive && url.startAccessingSecurityScopedResource() {
                    lock.lock()
                    activeSecurityScopedURLs[canonicalPath] = url
                    lock.unlock()
                }
            }
            return (true, isStale)
        } catch {
            return (false, true)
        }
    }

    private static func isDefaultFolder(_ canonicalPath: String) -> Bool {
        let lower = canonicalPath.lowercased()
        for def in defaultApprovedFolders {
            if let defCanon = try? normalizeAndResolvePathStatic(def), defCanon.lowercased() == lower {
                return true
            }
        }
        return false
    }

    private static func displayPath(for canonicalPath: String) -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        if canonicalPath == home || canonicalPath == NSHomeDirectory() {
            return "~"
        }
        if canonicalPath.hasPrefix(home + "/") {
            return "~/" + String(canonicalPath.dropFirst(home.count + 1))
        }
        if canonicalPath.hasPrefix(NSHomeDirectory() + "/") {
            return "~/" + String(canonicalPath.dropFirst(NSHomeDirectory().count + 1))
        }
        return canonicalPath
    }

    private static func loadBookmarks(from url: URL) -> [String: StoredBookmarkRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([StoredBookmarkRecord].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.canonicalPath, $0) })
    }

    private static func saveBookmarks(_ map: [String: StoredBookmarkRecord], to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        let sorted = map.values.sorted { $0.canonicalPath < $1.canonicalPath }
        if let data = try? JSONEncoder().encode(sorted) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
