import CryptoKit
import Foundation

public struct AuditRecord: Codable, Sendable {
    public let seq: Int
    public let timestamp: String
    public let prevHash: String
    public let entryHash: String
    public let tool: String
    public let args: [String: String]
    public let tier: Int
    public let trustState: String
    public let success: Bool
    
    public init(seq: Int, timestamp: String, prevHash: String, entryHash: String, tool: String, args: [String: String], tier: Int, trustState: String, success: Bool) {
        self.seq = seq
        self.timestamp = timestamp
        self.prevHash = prevHash
        self.entryHash = entryHash
        self.tool = tool
        self.args = args
        self.tier = tier
        self.trustState = trustState
        self.success = success
    }
    
    public static func formatArgs(_ args: [String: String]) -> String {
        if args.isEmpty { return "[:]" }
        return "[" + args.sorted(by: { $0.key < $1.key }).map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ", ") + "]"
    }
    
    public static func computeHash(
        seq: Int,
        timestamp: String,
        prevHash: String,
        tool: String,
        args: [String: String],
        tier: Int,
        trustState: String,
        success: Bool
    ) -> String {
        let formatted = formatArgs(args)
        let rawPayload = "\(seq)|\(timestamp)|\(prevHash)|\(tool)|\(formatted)|\(tier)|\(trustState)|\(success)"
        let digest = SHA256.hash(data: Data(rawPayload.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    public func recomputedHash() -> String {
        return AuditRecord.computeHash(
            seq: seq,
            timestamp: timestamp,
            prevHash: prevHash,
            tool: tool,
            args: args,
            tier: tier,
            trustState: trustState,
            success: success
        )
    }
}

/// Actor managing the SHA-256 hash-chained tamper-evident audit log.
///
/// Features:
/// - Full-chain verification from genesis on startup before appending.
/// - Fail-safe quarantine and explicit `isChainCorrupted` state if tampering is detected.
/// - Secret redaction prior to hashing and serialization.
/// - Durable `fsync` (`synchronize()`) disk writes.
public actor AuditLogger {
    public static let shared = AuditLogger()
    public static let genesisHash = "0000000000000000000000000000000000000000000000000000000000000000"
    
    private var lastHash: String = AuditLogger.genesisHash
    private var currentSeq: Int = 0
    private let logFileURL: URL
    
    public private(set) var isChainCorrupted: Bool = false
    public private(set) var chainIntegrityError: String? = nil
    
    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Pearl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        self.logFileURL = dir.appendingPathComponent("audit.log")
        
        // 1. Perform full-chain verification on boot
        if FileManager.default.fileExists(atPath: self.logFileURL.path) {
            let verification = AuditLogVerifier.shared.verifyFile(at: self.logFileURL)
            if !verification.isValid {
                self.isChainCorrupted = true
                self.chainIntegrityError = verification.failureReason
                NSLog("[AuditLogger] CRITICAL SECURITY ALERT: Audit log hash-chain verification failed! Reason: %@", verification.failureReason ?? "Unknown corruption")
                
                // Fail-safe quarantine: rotate corrupted log so attacker cannot obscure history
                let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let quarantinedURL = dir.appendingPathComponent("audit_corrupted_\(timestamp).log")
                try? FileManager.default.moveItem(at: self.logFileURL, to: quarantinedURL)
                
                self.currentSeq = 0
                self.lastHash = AuditLogger.genesisHash
            } else {
                let (seq, hash) = AuditLogger.readLastState(from: self.logFileURL)
                self.currentSeq = seq
                self.lastHash = hash
            }
        } else {
            self.currentSeq = 0
            self.lastHash = AuditLogger.genesisHash
        }
    }
    
    private nonisolated static func readLastState(from logFileURL: URL) -> (seq: Int, hash: String) {
        guard let data = try? Data(contentsOf: logFileURL),
              let content = String(data: data, encoding: .utf8) else {
            return (0, AuditLogger.genesisHash)
        }
        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let lastLine = lines.last,
              let record = try? JSONDecoder().decode(AuditRecord.self, from: Data(lastLine.utf8)) else {
            return (0, AuditLogger.genesisHash)
        }
        return (record.seq, record.entryHash)
    }
    
    public func log(tool: String, args: [String: String], tier: ToolTier, trustState: TrustLevel, success: Bool) {
        currentSeq += 1
        let isoDate = ISO8601DateFormatter().string(from: Date())
        
        // Redact potential secrets in args
        var safeArgs: [String: String] = [:]
        for (k, v) in args {
            let sanitizedVal = KeychainService.redact(text: v)
            if k.lowercased().contains("key") || k.lowercased().contains("secret") || k.lowercased().contains("token") || v.hasPrefix("sk-") {
                safeArgs[k] = "[REDACTED]"
            } else {
                safeArgs[k] = sanitizedVal
            }
        }
        
        let hashString = AuditRecord.computeHash(
            seq: currentSeq,
            timestamp: isoDate,
            prevHash: lastHash,
            tool: tool,
            args: safeArgs,
            tier: tier.rawValue,
            trustState: trustState.rawValue,
            success: success
        )
        
        let record = AuditRecord(
            seq: currentSeq,
            timestamp: isoDate,
            prevHash: lastHash,
            entryHash: hashString,
            tool: tool,
            args: safeArgs,
            tier: tier.rawValue,
            trustState: trustState.rawValue,
            success: success
        )
        
        lastHash = hashString
        
        // Durable, fsync-guaranteed disk append
        if let lineData = try? JSONEncoder().encode(record),
           var lineStr = String(data: lineData, encoding: .utf8) {
            lineStr.append("\n")
            if let writeData = lineStr.data(using: .utf8) {
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(writeData)
                    try? fileHandle.synchronize()
                    try? fileHandle.close()
                } else {
                    try? writeData.write(to: logFileURL, options: .atomic)
                }
            }
        }
    }
}
