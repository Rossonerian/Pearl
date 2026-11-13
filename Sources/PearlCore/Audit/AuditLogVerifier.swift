import CryptoKit
import Foundation

/// Result of an audit log hash-chain verification run.
public struct AuditVerificationResult: Sendable {
    public let isValid: Bool
    public let totalRecords: Int
    public let corruptedSequence: Int?
    public let failureReason: String?
    public let verifiedFiles: [String]
    
    public init(
        isValid: Bool,
        totalRecords: Int,
        corruptedSequence: Int?,
        failureReason: String?,
        verifiedFiles: [String]
    ) {
        self.isValid = isValid
        self.totalRecords = totalRecords
        self.corruptedSequence = corruptedSequence
        self.failureReason = failureReason
        self.verifiedFiles = verifiedFiles
    }
    
    public static func success(totalRecords: Int, verifiedFiles: [String]) -> AuditVerificationResult {
        return AuditVerificationResult(
            isValid: true,
            totalRecords: totalRecords,
            corruptedSequence: nil,
            failureReason: nil,
            verifiedFiles: verifiedFiles
        )
    }
    
    public static func failure(
        totalRecords: Int,
        corruptedSequence: Int,
        reason: String,
        verifiedFiles: [String]
    ) -> AuditVerificationResult {
        return AuditVerificationResult(
            isValid: false,
            totalRecords: totalRecords,
            corruptedSequence: corruptedSequence,
            failureReason: reason,
            verifiedFiles: verifiedFiles
        )
    }
}

/// Verification utility that reads audit logs (`audit/*.jsonl` or `audit.log`)
/// and recalculates the SHA-256 hash chain end-to-end.
/// Detects any line modification, deletion, reordering, or tampering and reports
/// the exact corrupted sequence number.
public final class AuditLogVerifier: Sendable {
    public static let shared = AuditLogVerifier()
    public static let genesisHash = "0000000000000000000000000000000000000000000000000000000000000000"
    
    public init() {}
    
    /// Verifies audit records contained within raw string lines.
    public func verifyLines(_ lines: [String], sourceName: String = "memory") -> AuditVerificationResult {
        let cleanLines = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        
        guard !cleanLines.isEmpty else {
            return .success(totalRecords: 0, verifiedFiles: [sourceName])
        }
        
        var expectedSeq = 1
        var expectedPrevHash = AuditLogVerifier.genesisHash
        var verifiedCount = 0
        
        for (idx, line) in cleanLines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONDecoder().decode(AuditRecord.self, from: data) else {
                return .failure(
                    totalRecords: verifiedCount,
                    corruptedSequence: expectedSeq,
                    reason: "Malformed JSON on line \(idx + 1) in \(sourceName)",
                    verifiedFiles: [sourceName]
                )
            }
            
            // 1. Verify sequence order
            if record.seq != expectedSeq {
                return .failure(
                    totalRecords: verifiedCount,
                    corruptedSequence: record.seq,
                    reason: "Sequence anomaly at line \(idx + 1): expected sequence \(expectedSeq), found \(record.seq) (potential deletion or insertion)",
                    verifiedFiles: [sourceName]
                )
            }
            
            // 2. Verify backwards hash pointer
            if record.prevHash != expectedPrevHash {
                return .failure(
                    totalRecords: verifiedCount,
                    corruptedSequence: record.seq,
                    reason: "Broken hash chain at sequence \(record.seq): expected prevHash '\(expectedPrevHash)', found '\(record.prevHash)'",
                    verifiedFiles: [sourceName]
                )
            }
            
            // 3. Recalculate entry SHA-256 hash
            let recalculated = record.recomputedHash()
            if recalculated != record.entryHash {
                return .failure(
                    totalRecords: verifiedCount,
                    corruptedSequence: record.seq,
                    reason: "Tampered record at sequence \(record.seq): recalculated SHA-256 '\(recalculated)' does not match recorded entryHash '\(record.entryHash)'",
                    verifiedFiles: [sourceName]
                )
            }
            
            expectedPrevHash = record.entryHash
            expectedSeq += 1
            verifiedCount += 1
        }
        
        return .success(totalRecords: verifiedCount, verifiedFiles: [sourceName])
    }
    
    /// Verifies a single audit log file at a given URL.
    public func verifyFile(at url: URL) -> AuditVerificationResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success(totalRecords: 0, verifiedFiles: [url.path])
        }
        
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure(
                totalRecords: 0,
                corruptedSequence: 1,
                reason: "Failed to read file at \(url.path)",
                verifiedFiles: [url.path]
            )
        }
        
        let lines = content.components(separatedBy: .newlines)
        return verifyLines(lines, sourceName: url.lastPathComponent)
    }
    
    /// Verifies all audit files in a directory (`*.jsonl` and `*.log`).
    public func verifyDirectory(at directoryURL: URL) -> AuditVerificationResult {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return .success(totalRecords: 0, verifiedFiles: [])
        }
        
        let logFiles = items.filter { $0.pathExtension == "jsonl" || $0.lastPathComponent == "audit.log" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        
        guard !logFiles.isEmpty else {
            return .success(totalRecords: 0, verifiedFiles: [])
        }
        
        var totalRecords = 0
        var verifiedFiles: [String] = []
        var expectedSeq = 1
        var expectedPrevHash = AuditLogVerifier.genesisHash
        
        for file in logFiles {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                return .failure(
                    totalRecords: totalRecords,
                    corruptedSequence: expectedSeq,
                    reason: "Failed to read audit log \(file.lastPathComponent)",
                    verifiedFiles: verifiedFiles
                )
            }
            
            let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            for (idx, line) in lines.enumerated() {
                guard let data = line.data(using: .utf8),
                      let record = try? JSONDecoder().decode(AuditRecord.self, from: data) else {
                    return .failure(
                        totalRecords: totalRecords,
                        corruptedSequence: expectedSeq,
                        reason: "Malformed record on line \(idx + 1) in \(file.lastPathComponent)",
                        verifiedFiles: verifiedFiles + [file.lastPathComponent]
                    )
                }
                
                if record.seq != expectedSeq {
                    return .failure(
                        totalRecords: totalRecords,
                        corruptedSequence: record.seq,
                        reason: "Sequence gap at sequence \(record.seq) in \(file.lastPathComponent): expected \(expectedSeq)",
                        verifiedFiles: verifiedFiles + [file.lastPathComponent]
                    )
                }
                
                if record.prevHash != expectedPrevHash {
                    return .failure(
                        totalRecords: totalRecords,
                        corruptedSequence: record.seq,
                        reason: "Hash chain discontinuity at sequence \(record.seq) in \(file.lastPathComponent): expected prevHash '\(expectedPrevHash)', got '\(record.prevHash)'",
                        verifiedFiles: verifiedFiles + [file.lastPathComponent]
                    )
                }
                
                let recalculated = record.recomputedHash()
                if recalculated != record.entryHash {
                    return .failure(
                        totalRecords: totalRecords,
                        corruptedSequence: record.seq,
                        reason: "Data tampering detected at sequence \(record.seq) in \(file.lastPathComponent): SHA-256 hash mismatch",
                        verifiedFiles: verifiedFiles + [file.lastPathComponent]
                    )
                }
                
                expectedPrevHash = record.entryHash
                expectedSeq += 1
                totalRecords += 1
            }
            verifiedFiles.append(file.lastPathComponent)
        }
        
        return .success(totalRecords: totalRecords, verifiedFiles: verifiedFiles)
    }
    
    /// Verifies the system default Pearl audit logs in `~/Library/Application Support/Pearl`.
    public func verifyDefaultAuditLogs() -> AuditVerificationResult {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let pearlDir = appSupport.appendingPathComponent("Pearl", isDirectory: true)
        let auditDir = pearlDir.appendingPathComponent("audit", isDirectory: true)
        
        if FileManager.default.fileExists(atPath: auditDir.path) {
            let res = verifyDirectory(at: auditDir)
            if res.totalRecords > 0 || !res.isValid {
                return res
            }
        }
        
        let legacyLog = pearlDir.appendingPathComponent("audit.log")
        return verifyFile(at: legacyLog)
    }
}
