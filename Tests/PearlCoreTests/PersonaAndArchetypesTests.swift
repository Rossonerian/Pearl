import XCTest
@testable import PearlCore

final class PersonaAndArchetypesTests: XCTestCase {
    
    private var tempDirectory: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try super.tearDownWithError()
    }
    
    // MARK: - 1. PersonaEngine Persistence
    
    func testPersonaEnginePersistenceAcrossInstances() {
        let stateURL = tempDirectory.appendingPathComponent("persona_test.json")
        let engine1 = PersonaEngine(stateFileURL: stateURL)
        
        XCTAssertEqual(engine1.activeMode, .executive)
        engine1.setMode(.ultron)
        XCTAssertEqual(engine1.activeMode, .ultron)
        
        // Second instance reading the same persisted state
        let engine2 = PersonaEngine(stateFileURL: stateURL)
        XCTAssertEqual(engine2.activeMode, .ultron)
        
        engine2.setMode(.jarvis)
        XCTAssertEqual(engine2.activeMode, .jarvis)
        
        let engine3 = PersonaEngine(stateFileURL: stateURL)
        XCTAssertEqual(engine3.activeMode, .jarvis)
    }
    
    // MARK: - 2. PersonaMode Metadata & System Prompt Prefix
    
    func testPersonaModeDisplayAndSystemPromptPrefix() {
        let stateURL = tempDirectory.appendingPathComponent("persona_test.json")
        let engine = PersonaEngine(stateFileURL: stateURL)
        
        // Test .executive
        engine.setMode(.executive)
        XCTAssertEqual(engine.activeMode.displayName, "Executive")
        XCTAssertFalse(engine.activeMode.description.isEmpty)
        let execPrompt = engine.systemPromptPrefix(for: .executive)
        XCTAssertTrue(execPrompt.contains("Executive"))
        XCTAssertTrue(execPrompt.contains("calm"))
        XCTAssertTrue(execPrompt.contains("concise"))
        
        // Test .ultron
        engine.setMode(.ultron)
        XCTAssertEqual(engine.activeMode.displayName, "Ultron")
        XCTAssertFalse(engine.activeMode.description.isEmpty)
        let ultronPrompt = engine.systemPromptPrefix(for: .ultron)
        XCTAssertTrue(ultronPrompt.contains("Ultron"))
        XCTAssertTrue(ultronPrompt.contains("roasts, then results"))
        XCTAssertTrue(ultronPrompt.contains("boss") || ultronPrompt.contains("sir"))
        
        // Test .jarvis
        engine.setMode(.jarvis)
        XCTAssertEqual(engine.activeMode.displayName, "Jarvis")
        XCTAssertFalse(engine.activeMode.description.isEmpty)
        let jarvisPrompt = engine.systemPromptPrefix(for: .jarvis)
        XCTAssertTrue(jarvisPrompt.contains("Jarvis"))
        XCTAssertTrue(jarvisPrompt.contains("butler"))
        
        // Default mode resolution when nil is passed
        XCTAssertEqual(engine.systemPromptPrefix(for: nil), jarvisPrompt)
    }
    
    // MARK: - 3. Decorate Response in Executive Mode
    
    func testDecorateResponseLeavesExecutiveUntouched() {
        let stateURL = tempDirectory.appendingPathComponent("persona_test.json")
        let engine = PersonaEngine(stateFileURL: stateURL)
        engine.setMode(.executive)
        
        let text = "Here are the files you requested."
        let decorated = engine.decorateResponse(text)
        XCTAssertEqual(decorated, text)
        
        let explicitlyDecorated = engine.decorateResponse(text, mode: .executive)
        XCTAssertEqual(explicitlyDecorated, text)
    }
    
    // MARK: - 4. Decorate Response Leaves JSON, Code, & Confirmation Untouched
    
    func testDecorateResponseLeavesStructuredContentUntouched() {
        let stateURL = tempDirectory.appendingPathComponent("persona_test.json")
        let engine = PersonaEngine(stateFileURL: stateURL)
        engine.setMode(.ultron)
        
        // Valid JSON dictionary
        let jsonDict = "{\"status\": \"ok\", \"count\": 42}"
        XCTAssertEqual(engine.decorateResponse(jsonDict), jsonDict)
        
        // Valid JSON array
        let jsonArray = "[\"item1\", \"item2\", \"item3\"]"
        XCTAssertEqual(engine.decorateResponse(jsonArray), jsonArray)
        
        // Structured markdown code block
        let codeBlock = "```swift\nfunc test() -> Bool {\n    return true\n}\n```"
        XCTAssertEqual(engine.decorateResponse(codeBlock), codeBlock)
        
        // Confirmation prompt or flag
        let confirmationText = "Confirmation required: are you sure?"
        XCTAssertEqual(engine.decorateResponse(confirmationText), confirmationText)
        
        let customConfirmation = "Run irreversible migration?"
        XCTAssertEqual(engine.decorateResponse(customConfirmation, isConfirmationOrJSON: true), customConfirmation)
        
        // Empty strings
        XCTAssertEqual(engine.decorateResponse(""), "")
        XCTAssertEqual(engine.decorateResponse("   \n\t  "), "   \n\t  ")
    }
    
    // MARK: - 5. Decorate Response in Ultron Mode & Idempotency
    
    func testDecorateResponseAppendsUltronQuipAndIsIdempotent() {
        let stateURL = tempDirectory.appendingPathComponent("persona_test.json")
        let engine = PersonaEngine(stateFileURL: stateURL)
        engine.setMode(.ultron)
        
        let text = "Compilation completed in 1.4s."
        let decorated = engine.decorateResponse(text, mode: .ultron)
        
        XCTAssertTrue(decorated.hasPrefix("Compilation completed in 1.4s.\n\n—"))
        XCTAssertTrue(decorated.contains("boss") || decorated.contains("sir"))
        
        // Decorating already decorated text should not append a second quip
        let reDecorated = engine.decorateResponse(decorated, mode: .ultron)
        XCTAssertEqual(reDecorated, decorated)
    }
    
    // MARK: - 6. Decorate Response in Jarvis Mode & Failure Quip
    
    func testDecorateResponseJarvisSuccessAndFailure() {
        let stateURL = tempDirectory.appendingPathComponent("persona_test.json")
        let engine = PersonaEngine(stateFileURL: stateURL)
        
        let successText = "Scheduled backup finished successfully."
        let decoratedSuccess = engine.decorateResponse(successText, mode: .jarvis, isActionSuccess: true)
        XCTAssertTrue(decoratedSuccess.hasPrefix("Scheduled backup finished successfully.\n\n—"))
        XCTAssertTrue(decoratedSuccess.contains("sir"))
        
        let failureText = "Failed to establish network connection."
        let decoratedFailure = engine.decorateResponse(failureText, mode: .jarvis, isActionSuccess: false)
        XCTAssertTrue(decoratedFailure.hasPrefix("Failed to establish network connection.\n\n—"))
        XCTAssertTrue(decoratedFailure.contains("sir"))
        XCTAssertTrue(
            decoratedFailure.contains("obstacle") ||
            decoratedFailure.contains("uncooperative") ||
            decoratedFailure.contains("apologies")
        )
    }
    
    // MARK: - 7. Spoken Quips
    
    func testSpokenQuipsPerPersonaMode() {
        let stateURL = tempDirectory.appendingPathComponent("persona_test.json")
        let engine = PersonaEngine(stateFileURL: stateURL)
        
        // Executive spoken quip should be nil
        XCTAssertNil(engine.spokenQuip(for: .executive))
        
        // Ultron spoken quip should be present
        let ultronQuip = engine.spokenQuip(for: .ultron)
        XCTAssertNotNil(ultronQuip)
        XCTAssertTrue(PersonaEngine.ultronSpokenQuips.contains(ultronQuip!))
        
        // Jarvis spoken quip should be present
        let jarvisQuip = engine.spokenQuip(for: .jarvis)
        XCTAssertNotNil(jarvisQuip)
        XCTAssertTrue(PersonaEngine.jarvisSpokenQuips.contains(jarvisQuip!))
    }
    
    // MARK: - 8. Specialist Archetype Metadata
    
    func testSpecialistArchetypeMetadata() {
        for archetype in SpecialistArchetype.allCases {
            XCTAssertFalse(archetype.displayName.isEmpty)
            XCTAssertFalse(archetype.domain.isEmpty)
            XCTAssertFalse(archetype.preferredTools.isEmpty)
            XCTAssertFalse(archetype.systemDirective.isEmpty)
        }
        
        XCTAssertEqual(SpecialistArchetype.athena.displayName, "Athena (Planner)")
        XCTAssertEqual(SpecialistArchetype.artemis.displayName, "Artemis (Researcher)")
        XCTAssertEqual(SpecialistArchetype.mnemosyne.displayName, "Mnemosyne (Vault Curator)")
        XCTAssertEqual(SpecialistArchetype.sisyphus.displayName, "Sisyphus (Batch Executor)")
    }
    
    // MARK: - 9. Specialist Archetype Parse Prefix
    
    func testSpecialistArchetypeParsePrefix() {
        // Athena
        let athenaRes = SpecialistArchetype.parsePrefix(from: "@athena plan the migration")
        XCTAssertEqual(athenaRes?.archetype, .athena)
        XCTAssertEqual(athenaRes?.strippedQuery, "plan the migration")
        
        // Athena with colon and case insensitivity
        let athenaColon = SpecialistArchetype.parsePrefix(from: "@ATHENA: plan the migration")
        XCTAssertEqual(athenaColon?.archetype, .athena)
        XCTAssertEqual(athenaColon?.strippedQuery, "plan the migration")
        
        // Artemis
        let artemisRes = SpecialistArchetype.parsePrefix(from: "@artemis find swift async docs")
        XCTAssertEqual(artemisRes?.archetype, .artemis)
        XCTAssertEqual(artemisRes?.strippedQuery, "find swift async docs")
        
        // Mnemosyne
        let mnemosyneRes = SpecialistArchetype.parsePrefix(from: "@mnemosyne recall key notes from yesterday")
        XCTAssertEqual(mnemosyneRes?.archetype, .mnemosyne)
        XCTAssertEqual(mnemosyneRes?.strippedQuery, "recall key notes from yesterday")
        
        // Sisyphus
        let sisyphusRes = SpecialistArchetype.parsePrefix(from: "@sisyphus run the batch sync loop")
        XCTAssertEqual(sisyphusRes?.archetype, .sisyphus)
        XCTAssertEqual(sisyphusRes?.strippedQuery, "run the batch sync loop")
        
        // Sisyphus alias: @sissyphous
        let aliasRes = SpecialistArchetype.parsePrefix(from: "@sissyphous, run the batch sync loop")
        XCTAssertEqual(aliasRes?.archetype, .sisyphus)
        XCTAssertEqual(aliasRes?.strippedQuery, "run the batch sync loop")
        
        let aliasUpper = SpecialistArchetype.parsePrefix(from: "@SISSYPHOUS: retry tests")
        XCTAssertEqual(aliasUpper?.archetype, .sisyphus)
        XCTAssertEqual(aliasUpper?.strippedQuery, "retry tests")
        
        // Non-matching inputs
        XCTAssertNil(SpecialistArchetype.parsePrefix(from: "Hello @athena"))
        XCTAssertNil(SpecialistArchetype.parsePrefix(from: "@unknownAgent do something"))
        XCTAssertNil(SpecialistArchetype.parsePrefix(from: "Plain text query"))
        XCTAssertNil(SpecialistArchetype.parsePrefix(from: ""))
        XCTAssertNil(SpecialistArchetype.parsePrefix(from: "@athenaclub is cool"))
    }
    
    // MARK: - 10. SubagentReportLedger Workflow
    
    func testSubagentReportLedgerWorkflow() throws {
        let reportsDir = tempDirectory.appendingPathComponent("reports")
        let ledger = SubagentReportLedger(reportsDirectory: reportsDir)
        let jobId = "job-42"
        
        let fileURL = try ledger.startReport(jobId: jobId, archetype: .athena, goal: "Migrate legacy database")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        
        guard let startedContent = ledger.readReport(jobId: jobId) else {
            XCTFail("Report was not read successfully")
            return
        }
        XCTAssertTrue(startedContent.contains("STARTED:"))
        XCTAssertTrue(startedContent.contains("Athena (Planner)"))
        XCTAssertTrue(startedContent.contains("Migrate legacy database"))
        XCTAssertTrue(startedContent.contains("## Execution Log"))
        
        // Append steps
        try ledger.appendStep(
            jobId: jobId,
            stepIndex: 1,
            totalSteps: 2,
            toolName: "db_scan",
            status: "completed",
            detail: "Scanned 100 tables",
            durationMs: 45.2
        )
        try ledger.appendStep(
            jobId: jobId,
            stepIndex: 2,
            totalSteps: 2,
            toolName: "db_migrate",
            status: "completed",
            detail: "Migrated cleanly",
            durationMs: 120.0
        )
        
        guard let stepContent = ledger.readReport(jobId: jobId) else {
            XCTFail("Report with steps was not read successfully")
            return
        }
        XCTAssertTrue(stepContent.contains("Step 1/2: [completed] tool=db_scan (45.2ms) - Scanned 100 tables"))
        XCTAssertTrue(stepContent.contains("Step 2/2: [completed] tool=db_migrate (120.0ms) - Migrated cleanly"))
        
        // Finalize report
        try ledger.finalizeReport(
            jobId: jobId,
            status: "SUCCESS",
            summary: "Database migration successful.",
            verification: "All 100 tables verified."
        )
        
        guard let finalContent = ledger.readReport(jobId: jobId) else {
            XCTFail("Finalized report was not read successfully")
            return
        }
        XCTAssertTrue(finalContent.contains("## Final Report"))
        XCTAssertTrue(finalContent.contains("Status: SUCCESS"))
        XCTAssertTrue(finalContent.contains("Summary: Database migration successful."))
        XCTAssertTrue(finalContent.contains("Verification: All 100 tables verified."))
        
        // List reports
        let reports = ledger.listReports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.lastPathComponent, "job-42.md")
    }
    
    // MARK: - 11. SubagentReportLedger Multiple Reports & Missing Report
    
    func testSubagentReportLedgerMultipleReports() throws {
        let reportsDir = tempDirectory.appendingPathComponent("multi_reports")
        let ledger = SubagentReportLedger(reportsDirectory: reportsDir)
        
        try ledger.startReport(jobId: "alpha-job", archetype: .artemis, goal: "Research competitors")
        try ledger.startReport(jobId: "beta-job", archetype: .sisyphus, goal: "Batch delete stale temp files")
        
        let reports = ledger.listReports()
        XCTAssertEqual(reports.count, 2)
        let fileNames = reports.map { $0.lastPathComponent }
        XCTAssertTrue(fileNames.contains("alpha-job.md"))
        XCTAssertTrue(fileNames.contains("beta-job.md"))
        
        // Reading non-existent report
        XCTAssertNil(ledger.readReport(jobId: "nonexistent-job"))
    }
}
