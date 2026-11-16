import Foundation

/// Generates Apple Seatbelt (.sb) sandboxing profiles for child processes.
/// Enforces deny-default write access and strict denial of sensitive system and user locations.
public struct SeatbeltProfile: Sendable {
    public let allowedReadPaths: [String]
    public let allowedWritePaths: [String]
    public let extraDeniedPaths: [String]
    public let allowNetwork: Bool

    /// Canonical sensitive paths that must NEVER be writable by any child process.
    public static var defaultSensitivePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appSupport = ("~/Library/Application Support/Pearl" as NSString).expandingTildeInPath
        return [
            "\(home)/.git/hooks",
            "\(home)/.git/config",
            "\(home)/.zshrc",
            "\(home)/.bashrc",
            "\(home)/.profile",
            "\(home)/.zshenv",
            "\(home)/.zprofile",
            "\(home)/Library/LaunchAgents",
            "\(home)/Library/Keychains",
            "\(home)/.ssh",
            "\(home)/.gnupg",
            "\(home)/.aws",
            "\(home)/.kube",
            "\(home)/.pearl",
            "\(home)/.config/gh",
            "\(home)/.git-credentials",
            "\(home)/.netrc",
            "\(home)/.npmrc",
            "\(home)/.pypirc",
            "\(home)/.docker",
            "\(home)/Library/Messages",
            "\(home)/Library/Mail",
            "\(home)/Library/Cookies",
            "\(home)/Library/Safari",
            "\(home)/Library/Group Containers",
            appSupport,
            "/Library/LaunchDaemons",
            "/Library/LaunchAgents",
            "/etc/hosts",
            "/private/etc/hosts"
        ]
    }

    public init(
        allowedReadPaths: [String] = [],
        allowedWritePaths: [String] = [],
        extraDeniedPaths: [String] = [],
        allowNetwork: Bool = false
    ) {
        self.allowedReadPaths = allowedReadPaths
        self.allowedWritePaths = allowedWritePaths
        self.extraDeniedPaths = extraDeniedPaths
        self.allowNetwork = allowNetwork
    }

    /// Checks if a given path targets or is inside any sensitive location.
    public static func isSensitivePath(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let canonical = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path.lowercased()
        let expLower = expanded.lowercased()
        
        for sensitive in defaultSensitivePaths {
            let expSens = (sensitive as NSString).expandingTildeInPath.lowercased()
            let canSens = URL(fileURLWithPath: expSens).resolvingSymlinksInPath().path.lowercased()
            
            if expLower == expSens || expLower.hasPrefix(expSens + "/") ||
               canonical == canSens || canonical.hasPrefix(canSens + "/") {
                return true
            }
        }
        return false
    }

    /// Generates the Seatbelt (.sb) Scheme profile text.
    public func generateProfileText() -> String {
        var lines: [String] = []
        lines.append("(version 1)")
        lines.append("(allow default)")
        
        // 1. Deny write by default
        lines.append(";; Default: Deny write access to all files")
        lines.append("(deny file-write*)")
        
        // 2. Allow writes to essential system character devices
        lines.append(";; Allow write to null, zero, tty devices")
        lines.append("(allow file-write* (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\"))")
        lines.append("(allow file-write-data (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\"))")
        
        // 3. Explicit allowed write locations
        if !allowedWritePaths.isEmpty {
            lines.append(";; Explicit allowed write directories")
            for rawPath in allowedWritePaths {
                let expanded = (rawPath as NSString).expandingTildeInPath
                let canonical = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
                lines.append("(allow file-write* (subpath \"\(expanded)\"))")
                if canonical != expanded {
                    lines.append("(allow file-write* (subpath \"\(canonical)\"))")
                }
            }
        }
        
        // 4. Strict denials: sensitive paths must ALWAYS override allows
        lines.append(";; Strict security: deny writes to sensitive paths")
        var allDenied = SeatbeltProfile.defaultSensitivePaths + extraDeniedPaths
        // Also add project-local .git/hooks and .git/config for any allowed write paths
        for writePath in allowedWritePaths {
            let expanded = (writePath as NSString).expandingTildeInPath
            allDenied.append("\(expanded)/.git/hooks")
            allDenied.append("\(expanded)/.git/config")
        }

        var addedSubpaths = Set<String>()
        for sensitive in allDenied {
            let expanded = (sensitive as NSString).expandingTildeInPath
            let canonical = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
            
            if !addedSubpaths.contains(expanded) {
                lines.append("(deny file-write* (subpath \"\(expanded)\"))")
                addedSubpaths.insert(expanded)
            }
            if !addedSubpaths.contains(canonical) {
                lines.append("(deny file-write* (subpath \"\(canonical)\"))")
                addedSubpaths.insert(canonical)
            }
        }
        
        // 5. Strict read denials for highly sensitive credentials
        lines.append(";; Deny read to sensitive credentials")
        let sensitiveReadRoots = [
            "~/.ssh",
            "~/.gnupg",
            "~/.aws",
            "~/.kube",
            "~/Library/Keychains",
            "~/Library/Application Support/Pearl"
        ]
        var addedReadSubpaths = Set<String>()
        for sensRead in sensitiveReadRoots {
            let expanded = (sensRead as NSString).expandingTildeInPath
            let canonical = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
            if !addedReadSubpaths.contains(expanded) {
                lines.append("(deny file-read* (subpath \"\(expanded)\"))")
                addedReadSubpaths.insert(expanded)
            }
            if !addedReadSubpaths.contains(canonical) {
                lines.append("(deny file-read* (subpath \"\(canonical)\"))")
                addedReadSubpaths.insert(canonical)
            }
        }
        
        // 6. Network controls
        if !allowNetwork {
            lines.append(";; Deny outbound network")
            lines.append("(deny network*)")
        }
        
        return lines.joined(separator: "\n") + "\n"
    }

    /// Predefined profile for git inspection commands
    public static func gitProfile(repoPath: String) -> SeatbeltProfile {
        let tempDir = NSTemporaryDirectory()
        return SeatbeltProfile(
            allowedWritePaths: [tempDir],
            extraDeniedPaths: [
                "\(repoPath)/.git/hooks",
                "\(repoPath)/.git/config"
            ],
            allowNetwork: false
        )
    }

    /// Predefined profile for build/compiler operations
    public static func compilerProfile(workspacePath: String) -> SeatbeltProfile {
        let tempDir = NSTemporaryDirectory()
        return SeatbeltProfile(
            allowedWritePaths: [workspacePath, tempDir],
            extraDeniedPaths: [
                "\(workspacePath)/.git/hooks",
                "\(workspacePath)/.git/config"
            ],
            allowNetwork: false
        )
    }

    /// Predefined profile for restricted child process execution
    public static func restrictedShellProfile(workspacePath: String, allowedWritePaths: [String] = []) -> SeatbeltProfile {
        var writeDirs = [workspacePath, NSTemporaryDirectory()]
        writeDirs.append(contentsOf: allowedWritePaths)
        return SeatbeltProfile(
            allowedWritePaths: writeDirs,
            extraDeniedPaths: [
                "\(workspacePath)/.git/hooks",
                "\(workspacePath)/.git/config"
            ],
            allowNetwork: false
        )
    }

    /// Maximum security profile denying all writes everywhere
    public static func strictDenyProfile() -> SeatbeltProfile {
        return SeatbeltProfile(
            allowedWritePaths: [],
            allowNetwork: false
        )
    }
}
