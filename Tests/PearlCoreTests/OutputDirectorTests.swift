import XCTest
@testable import PearlCore

final class OutputDirectorTests: XCTestCase {
    
    private let director = OutputDirector.shared
    
    // MARK: - Case 1: Confirmation Hold
    
    func testConfirmationRequiredOverridesOtherRules() {
        let text = "About to run `rm -rf /` which has irreversible side effects. User confirmation required."
        let decision = director.decide(
            responseText: text,
            origin: .voice,
            requiresConfirmation: true,
            userPresent: true
        )
        
        XCTAssertEqual(decision.mode, .speakSummaryAndHUD)
        XCTAssertEqual(decision.spokenText, "Confirmation required. Check the HUD to confirm or cancel.")
        XCTAssertEqual(decision.autoLeaveSeconds, 0.0)
        XCTAssertFalse(decision.dismissOnAppSwitch)
        XCTAssertEqual(decision.hudText, text)
    }
    
    // MARK: - Case 2: Away User (Silent Notification)
    
    func testAwayUserProducesSilentNotification() {
        let text = "Scheduled background scan finished."
        let decision = director.decide(
            responseText: text,
            origin: .voice,
            requiresConfirmation: false,
            userPresent: false
        )
        
        XCTAssertEqual(decision.mode, .silentNotification)
        XCTAssertNil(decision.spokenText)
        XCTAssertEqual(decision.autoLeaveSeconds, 2.0)
        XCTAssertTrue(decision.dismissOnAppSwitch)
        XCTAssertEqual(decision.hudText, text)
    }
    
    // MARK: - Case 3: Heavy / Structured Content
    
    func testCodeBlockTriggersSummaryAndHUDForVoice() {
        let text = "Here is the Swift function:\n```swift\nfunc greet() -> String {\n    return \"Hello\"\n}\n```\nAll done."
        let decision = director.decide(
            responseText: text,
            origin: .voice,
            requiresConfirmation: false,
            userPresent: true
        )
        
        XCTAssertEqual(decision.mode, .speakSummaryAndHUD)
        XCTAssertNotNil(decision.spokenText)
        XCTAssertTrue(decision.spokenText?.hasSuffix("Full details are shown in the HUD.") == true)
        XCTAssertFalse(decision.spokenText?.contains("func greet") == true)
        XCTAssertEqual(decision.autoLeaveSeconds, 7.0)
        XCTAssertTrue(decision.dismissOnAppSwitch)
    }
    
    func testCodeBlockTriggersHUDOnlyForCLI() {
        let text = "```bash\ngit status -s\n```"
        let decision = director.decide(
            responseText: text,
            origin: .cli,
            requiresConfirmation: false,
            userPresent: true
        )
        
        XCTAssertEqual(decision.mode, .hudOnly)
        XCTAssertNil(decision.spokenText)
        XCTAssertEqual(decision.autoLeaveSeconds, 7.0)
        XCTAssertTrue(decision.dismissOnAppSwitch)
    }
    
    func testMultiBulletListTriggersSummaryAndHUD() {
        let text = """
        Found 4 active processes:
        - Dock (PID 102)
        - Finder (PID 105)
        - WindowServer (PID 99)
        - Pearl (PID 340)
        """
        let decision = director.decide(
            responseText: text,
            origin: .voice,
            requiresConfirmation: false,
            userPresent: true
        )
        
        XCTAssertEqual(decision.mode, .speakSummaryAndHUD)
        XCTAssertNotNil(decision.spokenText)
        XCTAssertTrue(decision.spokenText?.hasSuffix("Full details are shown in the HUD.") == true)
        XCTAssertEqual(decision.autoLeaveSeconds, 7.0)
        XCTAssertTrue(decision.dismissOnAppSwitch)
    }
    
    func testMultiNumberedListTriggersSummaryAndHUD() {
        let text = """
        Execution steps:
        1. Compile source files
        2. Link object binaries
        3. Run unit tests
        4. Package deployment artifact
        """
        let decision = director.decide(
            responseText: text,
            origin: .voice,
            requiresConfirmation: false,
            userPresent: true
        )
        
        XCTAssertEqual(decision.mode, .speakSummaryAndHUD)
        XCTAssertNotNil(decision.spokenText)
        XCTAssertTrue(decision.spokenText?.hasSuffix("Full details are shown in the HUD.") == true)
        XCTAssertEqual(decision.autoLeaveSeconds, 7.0)
    }
    
    func testLongResponseOver220CharactersTriggersSummary() {
        let sentence1 = "The distributed system successfully replicated all write-ahead logs across 5 geographical availability zones."
        let sentence2 = "Secondary replicas confirmed quorum synchronization with zero detected data anomalies across the entire cluster partition."
        let fullText = "\(sentence1) \(sentence2)"
        XCTAssertGreaterThan(fullText.count, 220)
        
        let decision = director.decide(
            responseText: fullText,
            origin: .voice,
            requiresConfirmation: false,
            userPresent: true
        )
        
        XCTAssertEqual(decision.mode, .speakSummaryAndHUD)
        XCTAssertNotNil(decision.spokenText)
        XCTAssertTrue(decision.spokenText?.contains(sentence1) == true)
        XCTAssertTrue(decision.spokenText?.hasSuffix("Full details are shown in the HUD.") == true)
        XCTAssertEqual(decision.autoLeaveSeconds, 7.0)
    }
    
    // MARK: - Case 4: Short Conversational / Direct Action Reply
    
    func testShortVoiceReplySpeaksFullAndStripsMarkdown() {
        let text = "Volume set to **50%** on device `Built-in Speaker`."
        let decision = director.decide(
            responseText: text,
            origin: .voice,
            requiresConfirmation: false,
            userPresent: true
        )
        
        XCTAssertEqual(decision.mode, .speakFull)
        XCTAssertEqual(decision.spokenText, "Volume set to 50% on device Built-in Speaker.")
        XCTAssertEqual(decision.autoLeaveSeconds, 4.0)
        XCTAssertTrue(decision.dismissOnAppSwitch)
        XCTAssertEqual(decision.hudText, text)
    }
    
    func testShortCLIReplyIsHUDOnly() {
        let text = "Volume set to 50%."
        let decision = director.decide(
            responseText: text,
            origin: .cli,
            requiresConfirmation: false,
            userPresent: true
        )
        
        XCTAssertEqual(decision.mode, .hudOnly)
        XCTAssertNil(decision.spokenText)
        XCTAssertEqual(decision.autoLeaveSeconds, 4.0)
        XCTAssertTrue(decision.dismissOnAppSwitch)
    }
    
    // MARK: - Markdown Stripping
    
    func testStripMarkdownForSpeech() {
        let input = "## System Status\n**All** checks `passed` with [link](https://pearl.ai)."
        let stripped = director.stripMarkdownForSpeech(input)
        
        XCTAssertFalse(stripped.contains("##"))
        XCTAssertFalse(stripped.contains("**"))
        XCTAssertFalse(stripped.contains("`"))
        XCTAssertFalse(stripped.contains("https://pearl.ai"))
        XCTAssertTrue(stripped.contains("System Status"))
        XCTAssertTrue(stripped.contains("All checks passed with link."))
    }
    
    // MARK: - Summarization Logic
    
    func testSummarizeOnlyCodeBlockReturnsHUDReference() {
        let input = "```python\nprint('hello world')\n```"
        let summary = director.summarizeForSpeech(input)
        XCTAssertEqual(summary, "Full details are shown in the HUD.")
    }
    
    func testSummarizeLongSentenceCapsAt140Characters() {
        let longSentence = "This is an extraordinarily long sentence designed specifically to exceed the maximum character threshold of one hundred and forty characters in total length without any punctuation whatsoever"
        XCTAssertGreaterThan(longSentence.count, 140)
        
        let summary = director.summarizeForSpeech(longSentence)
        XCTAssertTrue(summary.hasSuffix(" Full details are shown in the HUD."))
        let prefixPart = summary.replacingOccurrences(of: " Full details are shown in the HUD.", with: "")
        XCTAssertLessThanOrEqual(prefixPart.count, 140)
    }
    
    // MARK: - AssistantPipeline Integration
    
    func testAssistantPipelineVoiceRequestPopulatesOutputDecision() async {
        let pipeline = AssistantPipeline.shared
        let request = AssistantRequest(utterance: "cancel that", origin: .voice)
        let response = await pipeline.process(request: request)
        
        XCTAssertNotNil(response.outputDecision)
        XCTAssertEqual(response.outputDecision?.mode, .speakFull)
        XCTAssertEqual(response.speechText, "Action cancelled.")
        XCTAssertEqual(response.outputDecision?.spokenText, "Action cancelled.")
        XCTAssertEqual(response.outputDecision?.autoLeaveSeconds, 4.0)
        XCTAssertTrue(response.outputDecision?.dismissOnAppSwitch == true)
    }
    
    func testAssistantPipelineCLIRequestPopulatesHUDOnlyDecision() async {
        let pipeline = AssistantPipeline.shared
        let request = AssistantRequest(utterance: "cancel that", origin: .cli)
        let response = await pipeline.process(request: request)
        
        XCTAssertNotNil(response.outputDecision)
        XCTAssertEqual(response.outputDecision?.mode, .hudOnly)
        XCTAssertNil(response.outputDecision?.spokenText)
        XCTAssertEqual(response.speechText, "")
        XCTAssertEqual(response.outputDecision?.autoLeaveSeconds, 4.0)
    }
}
