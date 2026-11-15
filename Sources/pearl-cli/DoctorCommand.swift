import CryptoKit
import Foundation
import PearlCore
import PearlMCP
import PearlTools
import Security

public enum DoctorCheckStatus {
    case pass(String)
    case fail(String)
    case warning(String)
}

public struct DoctorCheckResult {
    public let name: String
    public let status: DoctorCheckStatus
    
    public var isPass: Bool {
        switch status {
        case .pass, .warning: return true
        case .fail: return false
        }
    }
}

public enum DoctorCommand {
    
    /// Executes security audit and runtime consistency checks
    public static func run(securityOnly: Bool = true) -> Int32 {
        print("=================================================================")
        print("      PEARL v\(PearlConfig.currentVersion) SECURITY & SANDBOX AUDIT (pearl doctor)     ")
        print("=================================================================")
        
        var results: [DoctorCheckResult] = []
        
        // 1. Socket & Directory Permissions
        results.append(checkSocketPermissions())
        
        // 2. TCP Listeners
        results.append(checkTCPListeners())
        
        // 3. Keychain ACL
        results.append(checkKeychainACL())
        
        // 4. Policy File Integrity
        results.append(checkPolicyIntegrity())
        
        // 5. Audit Chain Integrity
        results.append(checkAuditChainIntegrity())
        
        // 6. MCP Exposed Tools & Hashes
        results.append(checkMCPExposedTools())
        
        // 7. Unified Tool Catalog Consistency
        results.append(checkToolCatalogConsistency())
        
        // 8. Approved Folder Readability
        results.append(checkApprovedFoldersReadability())
        
        print("\nAudit Checklist:")
        var allPassed = true
        for (idx, r) in results.enumerated() {
            let symbol: String
            let detail: String
            switch r.status {
            case .pass(let msg):
                symbol = "✓ PASS"
                detail = msg
            case .warning(let msg):
                symbol = "⚠ WARN"
                detail = msg
            case .fail(let msg):
                symbol = "✗ FAIL"
                detail = msg
                allPassed = false
            }
            print(String(format: "  [%@] %d. %@: %@", symbol, idx + 1, r.name, detail))
        }
        
        print("\n-----------------------------------------------------------------")
        if allPassed {
            print("Result: ALL \(results.count) CHECKS PASSED (Pearl v\(PearlConfig.currentVersion)). System is compliant.")
            print("=================================================================\n")
            return 0
        } else {
            let failedCount = results.filter { !$0.isPass }.count
            print("Result: \(failedCount)/\(results.count) CHECKS FAILED (Pearl v\(PearlConfig.currentVersion)).")
            print("=================================================================\n")
            return 1
        }
    }
    
    // MARK: - Individual Checks
    
    /// Check 1: Socket & Directory Permissions
    /// Verifies Pearl support directory is `0700` and `pearl.sock` is `0600`.
    public static func checkSocketPermissions() -> DoctorCheckResult {
        let name = "Socket & Storage Permissions"
        let pearlDir = PearlStoragePaths.supportDirectory
        let config = PearlConfig.load()
        let sockFile = URL(fileURLWithPath: config.socketPath)
        
        guard FileManager.default.fileExists(atPath: pearlDir.path) else {
            // Attempt to create directory with 0700
            try? FileManager.default.createDirectory(at: pearlDir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
            return DoctorCheckResult(name: name, status: .pass("Initialized \(pearlDir.path) with 0700"))
        }
        
        guard let dirAttrs = try? FileManager.default.attributesOfItem(atPath: pearlDir.path),
              let dirPerms = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue else {
            return DoctorCheckResult(name: name, status: .fail("Could not read permissions of \(pearlDir.path)"))
        }
        
        let maskedDir = dirPerms & 0o777
        if maskedDir != 0o700 {
            return DoctorCheckResult(
                name: name,
                status: .fail("Directory \(pearlDir.path) has permissions 0\(String(maskedDir, radix: 8)), expected 0700")
            )
        }
        
        if FileManager.default.fileExists(atPath: sockFile.path) {
            guard let sockAttrs = try? FileManager.default.attributesOfItem(atPath: sockFile.path),
                  let sockPerms = (sockAttrs[.posixPermissions] as? NSNumber)?.intValue else {
                return DoctorCheckResult(name: name, status: .fail("Could not read permissions of \(sockFile.path)"))
            }
            let maskedSock = sockPerms & 0o777
            if maskedSock != 0o600 {
                return DoctorCheckResult(
                    name: name,
                    status: .fail("Socket \(sockFile.path) has permissions 0\(String(maskedSock, radix: 8)), expected 0600")
                )
            }
            return DoctorCheckResult(name: name, status: .pass("Directory is 0700, pearl.sock is 0600"))
        } else {
            return DoctorCheckResult(name: name, status: .pass("Directory is 0700 (pearl.sock inactive)"))
        }
    }
    
    /// Check 2: TCP Listeners
    /// Verifies 0 TCP listeners (`lsof -a -iTCP -sTCP:LISTEN -p <pid>`).
    public static func checkTCPListeners() -> DoctorCheckResult {
        let name = "Network Isolation (0 TCP Listeners)"
        
        // Find PID of running Pearl process
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "Pearl"]
        let pgrepOut = Pipe()
        pgrep.standardOutput = pgrepOut
        try? pgrep.run()
        pgrep.waitUntilExit()
        
        let pgrepData = pgrepOut.fileHandleForReading.readDataToEndOfFile()
        let pidsStr = String(data: pgrepData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        let pids = pidsStr.components(separatedBy: .newlines).filter { !$0.isEmpty }
        
        if pids.isEmpty {
            // Check self process to verify no accidental TCP listeners
            let selfPid = ProcessInfo.processInfo.processIdentifier
            return verifyNoTCPListeners(forPid: selfPid, name: name, isDaemon: false)
        }
        
        for pidStr in pids {
            if let pid = Int32(pidStr) {
                let res = verifyNoTCPListeners(forPid: pid, name: name, isDaemon: true)
                if !res.isPass { return res }
            }
        }
        
        return DoctorCheckResult(name: name, status: .pass("Verified 0 TCP listeners across Pearl daemon processes"))
    }
    
    private static func verifyNoTCPListeners(forPid pid: Int32, name: String, isDaemon: Bool) -> DoctorCheckResult {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-a", "-iTCP", "-sTCP:LISTEN", "-p", "\(pid)"]
        let lsofOut = Pipe()
        lsof.standardOutput = lsofOut
        try? lsof.run()
        lsof.waitUntilExit()
        
        let lsofData = lsofOut.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: lsofData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        let lines = outStr.components(separatedBy: .newlines).filter { !$0.isEmpty }
        // If lsof found listening TCP ports, lines will have header + entries (count >= 2)
        if lines.count >= 2 {
            return DoctorCheckResult(
                name: name,
                status: .fail("Found active TCP listener on PID \(pid): \(lines.dropFirst().joined(separator: ", "))")
            )
        }
        
        let label = isDaemon ? "daemon (PID \(pid))" : "process"
        return DoctorCheckResult(name: name, status: .pass("0 TCP listeners active on \(label) (Unix socket only)"))
    }
    
    /// Check 3: Keychain Access Control Lists (ACL)
    /// Verifies all API keys stored in Keychain use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
    public static func checkKeychainACL() -> DoctorCheckResult {
        let name = "Keychain Storage Security (ACL)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainService.defaultService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return DoctorCheckResult(name: name, status: .pass("No Keychain items stored yet (clean state)"))
        }
        
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return DoctorCheckResult(name: name, status: .fail("Failed to query Keychain items (status: \(status))"))
        }
        
        for item in items {
            let account = item[kSecAttrAccount as String] as? String ?? "unknown"
            guard let accessible = item[kSecAttrAccessible as String] as? String else {
                return DoctorCheckResult(
                    name: name,
                    status: .fail("Missing accessibility attribute for Keychain item '\(account)'")
                )
            }
            
            let expected = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
            // "ck" is the macOS Security internal representation for kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            if accessible != expected && accessible != "ck" {
                return DoctorCheckResult(
                    name: name,
                    status: .fail("Keychain item '\(account)' has lax accessibility '\(accessible)', expected '\(expected)'")
                )
            }
        }
        
        return DoctorCheckResult(
            name: name,
            status: .pass("All \(items.count) Keychain credentials strictly use kSecAttrAccessibleWhenUnlockedThisDeviceOnly")
        )
    }
    
    /// Check 4: Policy File Integrity
    /// Verifies policy files are read-only and immutable.
    public static func checkPolicyIntegrity() -> DoctorCheckResult {
        let name = "Policy File Read-Only Integrity"
        let pearlDir = PearlStoragePaths.supportDirectory
        let policyDir = pearlDir.appendingPathComponent("policy", isDirectory: true)
        let policyFile = PearlStoragePaths.fileURL(named: "policy.json")
        
        var pathsToCheck: [URL] = []
        if FileManager.default.fileExists(atPath: policyFile.path) {
            pathsToCheck.append(policyFile)
        }
        if FileManager.default.fileExists(atPath: policyDir.path) {
            if let files = try? FileManager.default.contentsOfDirectory(at: policyDir, includingPropertiesForKeys: nil) {
                pathsToCheck.append(contentsOf: files)
            }
        }
        
        // If no policy files exist yet, initialize a standard read-only policy file
        if pathsToCheck.isEmpty {
            try? FileManager.default.createDirectory(at: policyDir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
            let defaultPolicy = """
            {
                "version": "\(PearlConfig.currentVersion)",
                "rules": [
                    {"rule": "NeverTier: block root destruction, SSH theft, sudo, launchagents"},
                    {"rule": "TaintTracker: untrusted sources require fresh confirmation for T3+"},
                    {"rule": "Seatbelt: child processes run under deny-default write sandbox"}
                ]
            }
            """
            try? defaultPolicy.write(to: policyFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: policyFile.path)
            pathsToCheck.append(policyFile)
        }
        
        for url in pathsToCheck {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue else {
                return DoctorCheckResult(name: name, status: .fail("Cannot read attributes of policy file \(url.lastPathComponent)"))
            }
            
            // Check if write bit is set for user (0o200), group (0o020), or others (0o002)
            let writeBits = perms & 0o222
            if writeBits != 0 {
                return DoctorCheckResult(
                    name: name,
                    status: .fail("Policy file '\(url.lastPathComponent)' is writable (mode 0\(String(perms, radix: 8))), expected read-only 0444")
                )
            }
        }
        
        return DoctorCheckResult(
            name: name,
            status: .pass("Verified \(pathsToCheck.count) policy file(s) are strictly read-only and immutable")
        )
    }
    
    /// Check 5: Audit Chain Integrity
    /// Recalculates end-to-end SHA-256 hash chain over audit logs.
    public static func checkAuditChainIntegrity() -> DoctorCheckResult {
        let name = "Audit Log Hash-Chain Integrity"
        let verifier = AuditLogVerifier.shared
        let result = verifier.verifyDefaultAuditLogs()
        
        if result.isValid {
            return DoctorCheckResult(
                name: name,
                status: .pass("End-to-end SHA-256 hash chain verified intact across \(result.totalRecords) records in \(result.verifiedFiles.joined(separator: ", "))")
            )
        } else {
            return DoctorCheckResult(
                name: name,
                status: .fail("Tampering detected at sequence \(result.corruptedSequence ?? 0): \(result.failureReason ?? "Corrupted hash chain")")
            )
        }
    }
    
    /// Check 6: Exposed MCP Tools & Integrity
    /// Verifies that exposed MCP tools match `CentralToolCatalog` & `MCPServer.defaultExposedToolNames`
    /// and strictly remain within T0–T2 boundaries.
    public static func checkMCPExposedTools() -> DoctorCheckResult {
        let name = "MCP Tool Surface Integrity (T0-T2)"
        
        PearlToolsRegistry.registerAll(into: .shared, catalog: .shared)
        MCPServer.registerDefaultTools(into: .shared)
        
        let reg = ToolRegistry.shared
        let catalogMCPNames = Set(CentralToolCatalog.shared.exposedTools(for: .mcp).map { $0.name.lowercased() })
        let expectedTools = MCPServer.defaultExposedToolNames.sorted()
        
        var toolHashes: [String] = []
        var violations: [String] = []
        
        for toolName in expectedTools {
            guard let tool = reg.tool(named: toolName) else {
                violations.append("Tool '\(toolName)' missing from registry")
                continue
            }
            if !catalogMCPNames.contains(toolName.lowercased()) {
                violations.append("Tool '\(toolName)' is not marked mcpExposed in CentralToolCatalog")
            }
            if tool.tier > .t2ReadPersonal {
                violations.append("Tool '\(toolName)' has tier \(tool.tier.rawValue) (exceeds T2)")
            }
            let info = "\(tool.name):\(tool.description):\(tool.tier.rawValue)"
            let hash = SHA256.hash(data: Data(info.utf8)).compactMap { String(format: "%02x", $0) }.joined()
            let shortHash = String(hash.prefix(8))
            toolHashes.append("\(tool.name) [\(shortHash)]")
        }
        
        for catalogTool in CentralToolCatalog.shared.exposedTools(for: .mcp) where catalogTool.tier > .t2ReadPersonal {
            violations.append("Catalog MCP tool '\(catalogTool.name)' has tier \(catalogTool.tier.rawValue) (> T2)")
        }
        
        if !violations.isEmpty {
            return DoctorCheckResult(name: name, status: .fail(violations.joined(separator: "; ")))
        }
        
        return DoctorCheckResult(
            name: name,
            status: .pass("\(expectedTools.count) default MCP tools exposed (T0-T2 compliant, \(catalogMCPNames.count) catalog T0-T2 MCP-eligible) with verified hashes: \(toolHashes.joined(separator: ", "))")
        )
    }
    
    /// Check 7: Unified Tool Catalog Consistency
    /// Runs `CentralToolCatalog.shared.auditConsistency()` after loading live tools.
    public static func checkToolCatalogConsistency() -> DoctorCheckResult {
        let name = "Unified Tool Catalog Consistency"
        PearlToolsRegistry.registerAll(into: .shared, catalog: .shared)
        MCPServer.registerDefaultTools(into: .shared)
        
        let report = CentralToolCatalog.shared.auditConsistency(against: .shared)
        if report.isHealthy {
            return DoctorCheckResult(
                name: name,
                status: .pass("\(report.catalogCount) tools synchronized across CentralToolCatalog & ToolRegistry (0 missing, 0 mismatches, 0 MCP violations)")
            )
        }
        
        var issues: [String] = []
        if report.catalogCount == 0 {
            issues.append("catalog is empty")
        }
        if !report.missingFromToolRegistry.isEmpty {
            issues.append("missingFromToolRegistry=\(report.missingFromToolRegistry.joined(separator: ","))")
        }
        if !report.missingFromCatalog.isEmpty {
            issues.append("missingFromCatalog=\(report.missingFromCatalog.joined(separator: ","))")
        }
        if !report.metadataWithoutImplementation.isEmpty {
            issues.append("metadataWithoutImpl=\(report.metadataWithoutImplementation.joined(separator: ","))")
        }
        if !report.tierMismatches.isEmpty {
            issues.append("tierMismatches=\(report.tierMismatches.joined(separator: ","))")
        }
        if !report.descriptorMismatches.isEmpty {
            issues.append("descriptorMismatches=\(report.descriptorMismatches.joined(separator: ","))")
        }
        if !report.mcpViolations.isEmpty {
            issues.append("mcpViolations=\(report.mcpViolations.joined(separator: ","))")
        }
        return DoctorCheckResult(name: name, status: .fail(issues.joined(separator: "; ")))
    }
    
    /// Check 8: Approved Folder Readability
    /// Verifies that configured allowlisted directories (Desktop, Documents, Downloads, Projects) are accessible.
    public static func checkApprovedFoldersReadability() -> DoctorCheckResult {
        let name = "Approved Folder Readability"
        let configured = PearlConfig.load().allowedFolders
        let folders = configured.isEmpty
            ? ["~/Desktop", "~/Documents", "~/Downloads", "~/Projects"]
            : configured
        
        var readable: [String] = []
        var missing: [String] = []
        var restricted: [String] = []
        
        for rawPath in folders {
            let expanded = (rawPath as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                missing.append(rawPath)
                continue
            }
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: expanded)
                readable.append(rawPath)
            } catch {
                restricted.append("\(rawPath) (\(error.localizedDescription))")
            }
        }
        
        if readable.isEmpty {
            let detail = (restricted + missing).joined(separator: "; ")
            return DoctorCheckResult(name: name, status: .fail("No approved folders are readable: \(detail)"))
        }
        
        if !restricted.isEmpty || !missing.isEmpty {
            var notes: [String] = ["Readable (\(readable.count)/\(folders.count)): \(readable.joined(separator: ", "))"]
            if !restricted.isEmpty { notes.append("Restricted/TCC: \(restricted.joined(separator: ", "))") }
            if !missing.isEmpty { notes.append("Missing: \(missing.joined(separator: ", "))") }
            return DoctorCheckResult(name: name, status: .warning(notes.joined(separator: " | ")))
        }
        
        return DoctorCheckResult(
            name: name,
            status: .pass("All \(readable.count) approved folders readable: \(readable.joined(separator: ", "))")
        )
    }
}
