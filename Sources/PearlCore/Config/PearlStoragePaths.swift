import Foundation

/// Centralized Application Support directory resolver for Pearl.
///
/// Automatically isolates all storage (`config.json`, `audit.log`, `spend_tracker.json`,
/// SQLite stores, proposals, reminders, bookmarks) into an ephemeral temp directory when
/// running under XCTest or when `PEARL_TEST_MODE=1` / `PEARL_APP_SUPPORT_DIR` is set,
/// preventing tests from ever mutating live user data in `~/Library/Application Support/Pearl`.
public enum PearlStoragePaths: Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _overrideSupportDirectory: URL?
    private nonisolated(unsafe) static var _cachedTestDirectory: URL?

    public static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["PEARL_TEST_MODE"] == "1" { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        let procName = ProcessInfo.processInfo.processName.lowercased()
        return procName.contains("xctest")
    }

    public static func setOverrideSupportDirectory(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        _overrideSupportDirectory = url
    }

    public static var supportDirectory: URL {
        lock.lock()
        let overrideURL = _overrideSupportDirectory
        let cachedTest = _cachedTestDirectory
        lock.unlock()

        let resolved: URL
        if let overrideURL = overrideURL {
            resolved = overrideURL
        } else if let envDir = ProcessInfo.processInfo.environment["PEARL_APP_SUPPORT_DIR"],
                  !envDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved = URL(fileURLWithPath: (envDir as NSString).expandingTildeInPath, isDirectory: true)
        } else if isRunningTests {
            if let existing = cachedTest {
                resolved = existing
            } else {
                let testDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PearlTestSupport_\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                lock.lock()
                _cachedTestDirectory = testDir
                lock.unlock()
                resolved = testDir
            }
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            resolved = appSupport.appendingPathComponent("Pearl", isDirectory: true)
        }

        try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        return resolved
    }

    public static func fileURL(named filename: String) -> URL {
        return supportDirectory.appendingPathComponent(filename)
    }

    public static func subdirectory(named name: String) -> URL {
        let sub = supportDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        return sub
    }
}
