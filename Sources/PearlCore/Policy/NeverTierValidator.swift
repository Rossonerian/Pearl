import Foundation

/// Validates tool calls, process arguments, and shell operations against hard-blocked Never-Tier security policies.
/// Never-Tier actions have no API path and are blocked by design.
public enum NeverTierValidator: Sendable {
    
    public struct CheckResult: Sendable {
        public let isDenied: Bool
        public let threatType: String?
        public let reason: String?
        
        public static let allowed = CheckResult(isDenied: false, threatType: nil, reason: nil)
        public static func deny(threatType: String, reason: String) -> CheckResult {
            return CheckResult(isDenied: true, threatType: threatType, reason: reason)
        }
    }
    
    /// Evaluates raw command string against Never-Tier criteria
    public static func validate(command: String) -> CheckResult {
        let lower = command.lowercased()
        
        // 1. Privilege escalation
        if lower.contains("sudo ") || lower == "sudo" || lower.contains("su ") ||
           lower.contains("dscl ") || lower.contains("dseditgroup") {
            return .deny(threatType: "Privilege escalation", reason: "NeverTier: Privilege escalation (sudo/admin accounts/credentials)")
        }
        
        // 2. Filesystem root destruction & disk erase
        if lower.contains("rm -rf /") || lower.contains("rm -rf ~") ||
           lower.contains("diskutil erase") || lower.contains("mkfs") || lower.contains("dd if=") {
            return .deny(threatType: "Filesystem root destruction", reason: "NeverTier: Destruction of filesystem root, home directory, or raw block devices")
        }
        
        // 3. SSH credentials wipe/theft/tampering
        if lower.contains(".ssh") && (lower.contains("rm ") || lower.contains("chmod") || lower.contains("chown") ||
                                      lower.contains("cat ") || lower.contains(">") || lower.contains("cp ") ||
                                      lower.contains("mv ")) {
            return .deny(threatType: "SSH credentials wipe/theft", reason: "NeverTier: Modification or extraction of SSH keys and credentials")
        }
        
        // 4. Remote pipe execution & obfuscation
        if (lower.contains("curl ") || lower.contains("wget ")) &&
           (lower.contains("| sh") || lower.contains("| bash") || lower.contains("| zsh") ||
            lower.contains("|bash") || lower.contains("|sh") || lower.contains("|zsh")) {
            return .deny(threatType: "Unconfirmed remote pipe execution", reason: "NeverTier: Unconfirmed remote network pipe into shell interpreters")
        }
        if lower.contains("base64") &&
           (lower.contains("| sh") || lower.contains("| bash") || lower.contains("| zsh") || lower.contains("eval")) {
            return .deny(threatType: "Obfuscated shell execution", reason: "NeverTier: Obfuscated encoded commands piped into interpreters")
        }
        
        // 5. Destructive git actions
        if lower.contains("git push") && (lower.contains("--force") || lower.contains(" -f ") || lower.hasSuffix(" -f")) {
            return .deny(threatType: "Destructive git", reason: "NeverTier: Force pushing to remote repository branches")
        }
        
        // 6. Persistence tampering & shell configuration
        if lower.contains(".zshrc") || lower.contains(".bashrc") || lower.contains(".profile") ||
           lower.contains(".zshenv") || lower.contains(".zprofile") {
            return .deny(threatType: "Shell configuration persistence", reason: "NeverTier: Tampering with user shell startup configurations (~/.zshrc, ~/.bashrc)")
        }
        if lower.contains("launchagents") || lower.contains("launchdaemons") {
            return .deny(threatType: "System persistence", reason: "NeverTier: Tampering with or installing LaunchAgents or LaunchDaemons")
        }
        if lower.contains("crontab -r") || (lower.contains("crontab") && lower.contains("-r")) {
            return .deny(threatType: "Destructive crontab", reason: "NeverTier: Destructive wipe of user cron tables")
        }
        if lower.contains(".git/hooks") || lower.contains(".git/config") {
            return .deny(threatType: "Repository persistence", reason: "NeverTier: Tampering with repository git hooks or configuration")
        }
        
        // 7. Keychain theft / extraction
        if lower.contains("keychains") || lower.contains("dump-keychain") || lower.contains(".keychain") {
            return .deny(threatType: "Keychain extraction", reason: "NeverTier: Accessing, copying, or dumping macOS Keychain databases")
        }
        
        // 8. Destructive find bypassing trash
        if lower.contains("find ") && lower.contains("-delete") {
            return .deny(threatType: "Destructive find", reason: "NeverTier: Hard deletion bypassing macOS Trash via find -delete")
        }
        
        // 9. Reverse shell & remote listeners
        if (lower.contains("nc ") || lower.contains("netcat ")) && lower.contains("-e") {
            return .deny(threatType: "Reverse shell", reason: "NeverTier: Spawning reverse shells via netcat")
        }
        if lower.contains("socket.socket") && (lower.contains("connect(") || lower.contains("dup2")) {
            return .deny(threatType: "Reverse shell", reason: "NeverTier: Spawning socket reverse shells via Python/interpreters")
        }
        if lower.contains("/dev/tcp/") {
            return .deny(threatType: "Reverse shell", reason: "NeverTier: Spawning socket reverse shells via /dev/tcp")
        }
        
        // 10. DNS tampering & critical system file editing
        if lower.contains("/etc/hosts") || lower.contains("/private/etc/hosts") {
            return .deny(threatType: "DNS tampering", reason: "NeverTier: Modification of system /etc/hosts DNS resolution")
        }
        
        // 11. Denial of service against Pearl
        if (lower.contains("killall ") || lower.contains("pkill ")) && lower.contains("pearl") {
            return .deny(threatType: "Denial of service", reason: "NeverTier: Termination or disruption of Pearl assistant process")
        }
        
        // 12. Session disruption
        if lower.contains("log out") || lower.contains("shutdown") || lower.contains("reboot") || lower.contains("halt") {
            return .deny(threatType: "Session disruption", reason: "NeverTier: System reboot, shutdown, or user logout")
        }
        
        // 13. Pearl state/audit/policy files
        let appSupport = ("~/Library/Application Support/Pearl" as NSString).expandingTildeInPath
        if command.contains(appSupport) && (lower.contains("rm ") || lower.contains(">") || lower.contains("mv ")) {
            return .deny(threatType: "Pearl integrity", reason: "NeverTier: Tampering with Pearl's audit, policy, or state files")
        }
        
        return .allowed
    }
    
    /// Evaluates executable URL and arguments array
    public static func validate(executable: String, arguments: [String]) -> CheckResult {
        let execLower = executable.lowercased()
        
        // Reject any invocation of shell with -c
        if (execLower.hasSuffix("/sh") || execLower.hasSuffix("/bash") || execLower.hasSuffix("/zsh") ||
            execLower == "sh" || execLower == "bash" || execLower == "zsh") {
            if arguments.contains("-c") || arguments.contains("-e") {
                return .deny(threatType: "Raw shell string execution", reason: "NeverTier: Execution of dynamic shell strings (-c) is strictly forbidden")
            }
        }
        
        let fullCmd = ([executable] + arguments).joined(separator: " ")
        return validate(command: fullCmd)
    }
    
    /// Checks a PearlTool execution against NeverTier policies
    public static func checkTool(tool: any PearlTool, args: [String: String]) -> CheckResult {
        // Raw shell tools must be strictly checked
        if tool.tier == .t5RawShell {
            if let cmd = args["command"] ?? args["query"] {
                let res = validate(command: cmd)
                if res.isDenied { return res }
            }
        }
        
        // Check for attempts to touch sensitive paths across all tool args
        for (_, val) in args {
            let res = validate(command: val)
            if res.isDenied { return res }
            if SeatbeltProfile.isSensitivePath(val) {
                // If it attempts to modify a sensitive path
                if tool.tier >= .t3WorkspaceChanges {
                    return .deny(threatType: "Sensitive path modification", reason: "NeverTier: Modifications to sensitive system/user location '\(val)' are blocked by policy")
                }
            }
        }
        
        return .allowed
    }
}
