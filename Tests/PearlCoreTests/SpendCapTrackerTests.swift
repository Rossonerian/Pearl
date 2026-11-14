import XCTest
@testable import PearlCore

final class SpendCapTrackerTests: XCTestCase {
    var tracker: SpendCapTracker!
    
    override func setUp() {
        super.setUp()
        tracker = SpendCapTracker(monthlyCapUSD: 10.0, maxTokensPerTurn: 4096)
        tracker.resetForTesting(initialSpend: 0.0)
    }
    
    override func tearDown() {
        tracker.resetForTesting(initialSpend: 0.0)
        tracker = nil
        super.tearDown()
    }
    
    // MARK: - Turn Token Limit Checks
    
    func testTurnTokenLimitWithinThreshold() {
        XCTAssertNoThrow(try tracker.checkTurnTokenLimit(tokens: 100))
        XCTAssertNoThrow(try tracker.checkTurnTokenLimit(tokens: 4096))
    }
    
    func testTurnTokenLimitExceeded() {
        XCTAssertThrowsError(try tracker.checkTurnTokenLimit(tokens: 4097)) { error in
            guard let spendError = error as? SpendCapError else {
                return XCTFail("Expected SpendCapError, got \(error)")
            }
            if case .exceededPerTurnTokenCap(let requested, let max) = spendError {
                XCTAssertEqual(requested, 4097)
                XCTAssertEqual(max, 4096)
                XCTAssertTrue(spendError.localizedDescription.contains("Requested tokens (4097) exceeds maximum"))
            } else {
                XCTFail("Expected exceededPerTurnTokenCap, got \(spendError)")
            }
        }
    }
    
    // MARK: - Monthly Spend Cap Enforcement
    
    func testSpendCapInitialState() {
        XCTAssertEqual(tracker.currentSpend(), 0.0, accuracy: 0.0001)
        XCTAssertNoThrow(try tracker.checkSpendCap())
    }
    
    func testRecordUsageIncrementsSpend() {
        // Claude Haiku: $0.80 / MTok in, $4.00 / MTok out
        // 100,000 input = 0.08 USD, 50,000 output = 0.20 USD -> 0.28 USD
        let cost = tracker.recordUsage(modelID: "claude-3-5-haiku", inputTokens: 100_000, outputTokens: 50_000)
        XCTAssertEqual(cost, 0.28, accuracy: 0.001)
        XCTAssertEqual(tracker.currentSpend(), 0.28, accuracy: 0.001)
        XCTAssertNoThrow(try tracker.checkSpendCap())
    }
    
    func testRecordUsageSonnetRates() {
        // Claude Sonnet: $3.00 / MTok in, $15.00 / MTok out
        // 1,000,000 input = 3.00 USD, 100,000 output = 1.50 USD -> 4.50 USD
        let cost = tracker.recordUsage(modelID: "claude-3-5-sonnet", inputTokens: 1_000_000, outputTokens: 100_000)
        XCTAssertEqual(cost, 4.50, accuracy: 0.001)
        XCTAssertEqual(tracker.currentSpend(), 4.50, accuracy: 0.001)
    }
    
    func testMonthlySpendCapExceededThrowsError() {
        tracker.resetForTesting(initialSpend: 9.95)
        XCTAssertNoThrow(try tracker.checkSpendCap())
        
        // Add 0.10 USD spend to push over $10.00 cap
        _ = tracker.recordUsage(modelID: "claude-3-5-haiku", inputTokens: 100_000, outputTokens: 10_000)
        XCTAssertGreaterThanOrEqual(tracker.currentSpend(), 10.0)
        
        XCTAssertThrowsError(try tracker.checkSpendCap()) { error in
            guard let spendError = error as? SpendCapError else {
                return XCTFail("Expected SpendCapError, got \(error)")
            }
            if case .monthlySpendCapExceeded(let current, let cap) = spendError {
                XCTAssertGreaterThanOrEqual(current, 10.0)
                XCTAssertEqual(cap, 10.0)
                XCTAssertTrue(spendError.localizedDescription.contains("monthly spend cap exceeded"))
            } else {
                XCTFail("Expected monthlySpendCapExceeded, got \(spendError)")
            }
        }
    }
    
    // MARK: - Update Limits
    
    func testUpdateLimitsDynamically() {
        tracker.updateLimits(monthlyCapUSD: 25.0, maxTokensPerTurn: 8192)
        
        // Old turn limit 4096 would fail for 5000, now it should pass
        XCTAssertNoThrow(try tracker.checkTurnTokenLimit(tokens: 5000))
        XCTAssertThrowsError(try tracker.checkTurnTokenLimit(tokens: 8193))
        
        // Old spend cap 10.0 would fail for 15.0, now 15.0 should pass under 25.0 cap
        tracker.resetForTesting(initialSpend: 15.0)
        XCTAssertNoThrow(try tracker.checkSpendCap())
        
        tracker.resetForTesting(initialSpend: 25.01)
        XCTAssertThrowsError(try tracker.checkSpendCap())
    }
}
