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
}

public actor AuditLogger {
    public static let shared = AuditLogger()
    
    private var lastHash: String = "0000000000000000000000000000000000000000000000000000000000000000"
    private var currentSeq: Int = 0
    private let logFileURL: URL
    
    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Pearl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        self.logFileURL = dir.appendingPathComponent("audit.log")
        let (seq, hash) = AuditLogger.readLastState(from: self.logFileURL)
        self.currentSeq = seq
        self.lastHash = hash
    }
    
    private nonisolated static func readLastState(from logFileURL: URL) -> (seq: Int, hash: String) {
        guard let data = try? Data(contentsOf: logFileURL),
              let content = String(data: data, encoding: .utf8) else {
            return (0, "0000000000000000000000000000000000000000000000000000000000000000")
        }
        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let lastLine = lines.last,
              let record = try? JSONDecoder().decode(AuditRecord.self, from: Data(lastLine.utf8)) else {
            return (0, "0000000000000000000000000000000000000000000000000000000000000000")
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
        
        let rawPayload = "\(currentSeq)|\(isoDate)|\(lastHash)|\(tool)|\(safeArgs)|\(tier.rawValue)|\(trustState.rawValue)|\(success)"
        let digest = SHA256.hash(data: Data(rawPayload.utf8))
        let hashString = digest.compactMap { String(format: "%02x", $0) }.joined()
        
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
        
        if let lineData = try? JSONEncoder().encode(record),
           var lineStr = String(data: lineData, encoding: .utf8) {
            lineStr.append("\n")
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile()
                if let writeData = lineStr.data(using: .utf8) {
                    fileHandle.write(writeData)
                }
                try? fileHandle.close()
            } else {
                try? lineStr.write(to: logFileURL, atomically: true, encoding: .utf8)
            }
        }
    }
}
