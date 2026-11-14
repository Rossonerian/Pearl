import XCTest
import CryptoKit
@testable import PearlCore

final class AuditLoggerTests: XCTestCase {
    var verifier: AuditLogVerifier!
    var tempDirectory: URL!
    
    override func setUp() {
        super.setUp()
        verifier = AuditLogVerifier()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
        verifier = nil
        super.tearDown()
    }
    
    // MARK: - Hash Chain Computation & Invariants
    
    func testAuditRecordComputeHash() {
        let hash1 = AuditRecord.computeHash(
            seq: 1,
            timestamp: "2026-11-14T09:00:00Z",
            prevHash: AuditLogVerifier.genesisHash,
            tool: "volume",
            args: ["level": "50"],
            tier: 1,
            trustState: "trusted",
            success: true
        )
        
        XCTAssertFalse(hash1.isEmpty)
        XCTAssertEqual(hash1.count, 64, "SHA-256 hex string should be 64 characters")
        
        let record = AuditRecord(
            seq: 1,
            timestamp: "2026-11-14T09:00:00Z",
            prevHash: AuditLogVerifier.genesisHash,
            entryHash: hash1,
            tool: "volume",
            args: ["level": "50"],
            tier: 1,
            trustState: "trusted",
            success: true
        )
        
        XCTAssertEqual(record.recomputedHash(), hash1)
    }
    
    func testArgumentFormattingDeterministicOrder() {
        // Different insertion orders must yield identical format string and hash
        let args1 = ["zeta": "1", "alpha": "2", "beta": "3"]
        let args2 = ["alpha": "2", "beta": "3", "zeta": "1"]
        
        XCTAssertEqual(AuditRecord.formatArgs(args1), AuditRecord.formatArgs(args2))
        
        let hash1 = AuditRecord.computeHash(seq: 1, timestamp: "T", prevHash: "0", tool: "tool", args: args1, tier: 1, trustState: "trusted", success: true)
        let hash2 = AuditRecord.computeHash(seq: 1, timestamp: "T", prevHash: "0", tool: "tool", args: args2, tier: 1, trustState: "trusted", success: true)
        XCTAssertEqual(hash1, hash2)
    }
    
    func testAuditRecordEmptyArgsFormatting() {
        XCTAssertEqual(AuditRecord.formatArgs([:]), "[:]")
    }
    
    // MARK: - Multi-Record Synthetic Chain Verification
    
    private func generateValidChain(count: Int) -> [AuditRecord] {
        var records: [AuditRecord] = []
        var prevHash = AuditLogVerifier.genesisHash
        
        for i in 1...count {
            let timestamp = "2026-11-14T09:00:\(String(format: "%02d", i))Z"
            let args = ["index": "\(i)"]
            let hash = AuditRecord.computeHash(
                seq: i,
                timestamp: timestamp,
                prevHash: prevHash,
                tool: "tool_\(i)",
                args: args,
                tier: 1,
                trustState: "trusted",
                success: true
            )
            let record = AuditRecord(
                seq: i,
                timestamp: timestamp,
                prevHash: prevHash,
                entryHash: hash,
                tool: "tool_\(i)",
                args: args,
                tier: 1,
                trustState: "trusted",
                success: true
            )
            records.append(record)
            prevHash = hash
        }
        return records
    }
    
    private func serializeRecords(_ records: [AuditRecord]) -> [String] {
        return records.compactMap { record in
            guard let data = try? JSONEncoder().encode(record),
                  let str = String(data: data, encoding: .utf8) else {
                return nil
            }
            return str
        }
    }
    
    func testValidChainVerifiesSuccessfully() {
        let chain = generateValidChain(count: 25)
        let lines = serializeRecords(chain)
        
        let result = verifier.verifyLines(lines, sourceName: "test_valid")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.totalRecords, 25)
        XCTAssertNil(result.corruptedSequence)
        XCTAssertNil(result.failureReason)
    }
    
    func testEmptyLogVerifiesSuccessfully() {
        let result = verifier.verifyLines([], sourceName: "test_empty")
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.totalRecords, 0)
    }
    
    // MARK: - Tamper Detection via AuditLogVerifier
    
    func testTamperedPayloadDetected() {
        var chain = generateValidChain(count: 20)
        
        // Tamper record at seq 12 by modifying args without updating entryHash
        let victim = chain[11] // 0-indexed, seq 12
        let tamperedRecord = AuditRecord(
            seq: victim.seq,
            timestamp: victim.timestamp,
            prevHash: victim.prevHash,
            entryHash: victim.entryHash, // old hash
            tool: victim.tool,
            args: ["index": "12", "tampered": "true"], // altered args!
            tier: victim.tier,
            trustState: victim.trustState,
            success: victim.success
        )
        chain[11] = tamperedRecord
        
        let lines = serializeRecords(chain)
        let result = verifier.verifyLines(lines, sourceName: "test_tampered")
        
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.corruptedSequence, 12)
        XCTAssertTrue(result.failureReason?.contains("Tampered record at sequence 12") == true)
    }
    
    func testDeletedRecordDetected() {
        var chain = generateValidChain(count: 20)
        
        // Attacker deletes record at seq 8
        chain.remove(at: 7)
        
        let lines = serializeRecords(chain)
        let result = verifier.verifyLines(lines, sourceName: "test_deleted")
        
        XCTAssertFalse(result.isValid)
        // Sequence jump: expected 8, found 9
        XCTAssertEqual(result.corruptedSequence, 9)
        XCTAssertTrue(result.failureReason?.contains("Sequence anomaly") == true)
    }
    
    func testBrokenPrevHashPointerDetected() {
        var chain = generateValidChain(count: 10)
        
        // Manually alter prevHash of record 5
        let victim = chain[4]
        let corruptedRecord = AuditRecord(
            seq: victim.seq,
            timestamp: victim.timestamp,
            prevHash: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            entryHash: victim.entryHash,
            tool: victim.tool,
            args: victim.args,
            tier: victim.tier,
            trustState: victim.trustState,
            success: victim.success
        )
        chain[4] = corruptedRecord
        
        let lines = serializeRecords(chain)
        let result = verifier.verifyLines(lines, sourceName: "test_broken_prev")
        
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.corruptedSequence, 5)
        XCTAssertTrue(result.failureReason?.contains("Broken hash chain") == true)
    }
    
    func testMalformedJSONLineDetected() {
        var lines = serializeRecords(generateValidChain(count: 5))
        lines.insert("NOT_VALID_JSON_RECORD_LINE", at: 2)
        
        let result = verifier.verifyLines(lines, sourceName: "test_malformed")
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.failureReason?.contains("Malformed JSON") == true)
    }
    
    func testVerifyFileOnDisk() throws {
        let chain = generateValidChain(count: 10)
        let lines = serializeRecords(chain)
        let fileURL = tempDirectory.appendingPathComponent("audit.log")
        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        
        let result = verifier.verifyFile(at: fileURL)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.totalRecords, 10)
    }
    
    func testVerifyNonExistentFileReturnsSuccessWithZeroRecords() {
        let nonExistentURL = tempDirectory.appendingPathComponent("does_not_exist.log")
        let result = verifier.verifyFile(at: nonExistentURL)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.totalRecords, 0)
    }
}
