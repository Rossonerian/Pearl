import XCTest
@testable import PearlCore

final class FallbackChainTests: XCTestCase {
    
    func testOfflineCannedFallbackWhenAllTiersFail() async {
        // Create FallbackChain with default providers without API keys
        let chain = FallbackChain(pccEnabled: false)
        let context = ModelExecutionContext(forceEscalation: true) // Bypasses Apple FM
        
        let response = await chain.process(utterance: "What is the meaning of quantum computing?", context: context)
        
        XCTAssertNotNil(response)
        XCTAssertFalse(response.content.isEmpty)
        XCTAssertEqual(response.providerName, "Offline Fallback")
        XCTAssertEqual(response.modelID, "canned")
        XCTAssertTrue(response.isLocal)
        XCTAssertEqual(response.badge.provider, "Offline Fallback")
        XCTAssertTrue(response.content.contains("offline or unable to reach AI models"))
    }
    
    func testFallbackChainGeneratesExplicitExplanation() async {
        let chain = FallbackChain(pccEnabled: false)
        let context = ModelExecutionContext(forceEscalation: true)
        
        let response = await chain.process(utterance: "hello world", context: context)
        XCTAssertTrue(response.content.contains("Diagnostic summary of fallback chain:"))
    }
}
