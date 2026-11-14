import XCTest
@testable import PearlCore
@testable import PearlTools

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class ToolExecutionTests: XCTestCase {
    
    override func setUp() async throws {
        try await super.setUp()
        await UndoJournal.shared.clear()
    }
    
    override func tearDown() async throws {
        await UndoJournal.shared.clear()
        try await super.tearDown()
    }
    
    // MARK: - VolumeTool Execution & Undo
    
    func testVolumeToolGetVolumeWhenMissingArgs() async throws {
        let tool = VolumeTool()
        let context = ToolExecutionContext(trustState: .trusted)
        
        let result = try await tool.execute(args: [:], context: context)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.message.contains("Current volume is"))
        XCTAssertNil(result.undoAction, "Querying volume should not register undo action")
    }
    
    func testVolumeToolSetVolumeAndReversibility() async throws {
        let tool = VolumeTool()
        let context = ToolExecutionContext(trustState: .trusted)
        let originalVol = tool.getVolume()
        
        let result = try await tool.execute(args: ["level": "42"], context: context)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.message.contains("42%"))
        XCTAssertNotNil(result.undoAction, "Setting volume must provide undoAction")
        
        // Execute undo action
        try await result.undoAction?()
        
        // Volume should be restored to original
        let restoredVol = tool.getVolume()
        XCTAssertEqual(restoredVol, originalVol, accuracy: 0.05)
    }
    
    func testVolumeToolMute() async throws {
        let tool = VolumeTool()
        let context = ToolExecutionContext(trustState: .trusted)
        
        let result = try await tool.execute(args: ["level": "0"], context: context)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.message, "Volume muted (0%).")
        XCTAssertNotNil(result.undoAction)
        
        // Cleanup undo
        try await result.undoAction?()
    }
    
    func testVolumeToolClamping() async throws {
        let tool = VolumeTool()
        let context = ToolExecutionContext(trustState: .trusted)
        
        // > 100 clamped to 100
        let r1 = try await tool.execute(args: ["level": "150"], context: context)
        XCTAssertTrue(r1.success)
        XCTAssertTrue(r1.message.contains("100%"))
        try await r1.undoAction?()
        
        // < 0 clamped to 0
        let r2 = try await tool.execute(args: ["level": "-10"], context: context)
        XCTAssertTrue(r2.success)
        XCTAssertEqual(r2.message, "Volume muted (0%).")
        try await r2.undoAction?()
    }
    
    // MARK: - AppTool Validation Errors
    
    func testAppToolMissingApplicationName() async throws {
        let tool = AppTool()
        let context = ToolExecutionContext(trustState: .trusted)
        
        let result1 = try await tool.execute(args: [:], context: context)
        XCTAssertFalse(result1.success)
        XCTAssertEqual(result1.message, "Missing application name.")
        
        let result2 = try await tool.execute(args: ["app": ""], context: context)
        XCTAssertFalse(result2.success)
        XCTAssertEqual(result2.message, "Missing application name.")
    }
    
    func testCloseAppToolMissingApplicationName() async throws {
        let tool = CloseAppTool()
        let context = ToolExecutionContext(trustState: .trusted)
        
        let result = try await tool.execute(args: [:], context: context)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.message, "Missing application name.")
    }
    
    func testCloseAppToolNonExistentAppFailsGracefully() async throws {
        let tool = CloseAppTool()
        let context = ToolExecutionContext(trustState: .trusted)
        
        let result = try await tool.execute(args: ["app": "NonExistentAppXYZ_12345"], context: context)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("is not running"))
    }
    
    // MARK: - GitStatusTool Argument Handling
    
    func testGitStatusToolOnValidGitRepo() async throws {
        let tool = GitStatusTool()
        let context = ToolExecutionContext(trustState: .trusted)
        
        let candidates = [
            "/Users/rossonerian/Projects/Pearl-worktrees/test-v3-quality-suite",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Projects/Pearl",
            FileManager.default.currentDirectoryPath
        ]
        let validPath = candidates.first { FileManager.default.fileExists(atPath: $0 + "/.git") } ?? FileManager.default.currentDirectoryPath
        
        let result = try await tool.execute(args: ["path": validPath], context: context)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.message.lowercased().contains("branch") || result.message.lowercased().contains("git"))
    }
    
    func testGitStatusToolOnInvalidPathReturnsFailure() async throws {
        let tool = GitStatusTool()
        let context = ToolExecutionContext(trustState: .trusted)
        
        let result = try await tool.execute(args: ["path": "/tmp"], context: context)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("is not a git repository"))
    }
    
    // MARK: - ReminderTool Execution & Undo
    
    func testReminderToolCreateAndUndo() async throws {
        let tool = ReminderTool()
        let context = ToolExecutionContext(trustState: .trusted)
        let uniqueTitle = "Unit Test Reminder \(UUID().uuidString)"
        
        let createResult = try await tool.execute(args: ["title": uniqueTitle], context: context)
        XCTAssertTrue(createResult.success)
        XCTAssertTrue(createResult.message.contains("Added") || createResult.message.contains(uniqueTitle))
        XCTAssertNotNil(createResult.undoAction, "Creating reminder should provide undoAction")
        
        // Verify reminder listed
        let listResult = try await tool.execute(args: ["action": "list"], context: context)
        XCTAssertTrue(listResult.success)
        XCTAssertTrue(listResult.message.contains(uniqueTitle))
        
        // Execute undo action
        try await createResult.undoAction?()
        
        // Verify reminder removed after undo
        let listAfterUndo = try await tool.execute(args: ["action": "list"], context: context)
        XCTAssertFalse(listAfterUndo.message.contains(uniqueTitle))
    }
    
    // MARK: - TrashScreenshotsTool
    
    func testTrashScreenshotsToolWhenEmpty() async throws {
        let tool = TrashScreenshotsTool()
        let context = ToolExecutionContext(trustState: .trusted)
        
        let result = try await tool.execute(args: [:], context: context)
        XCTAssertTrue(result.success)
        // Either "No screenshots found to clean up." or "Moved X screenshot(s) to Trash."
        XCTAssertFalse(result.message.isEmpty)
    }
    
    // MARK: - UndoJournal Registration & Undo Execution
    
    func testUndoJournalRegistrationAndExecution() async throws {
        let journal = UndoJournal.shared
        await journal.clear()
        
        let executedBox = Box(false)
        await journal.register(toolName: "test_tool") {
            executedBox.value = true
        }
        
        let count = await journal.count
        XCTAssertEqual(count, 1)
        
        let undoMessage = try await journal.undoLast()
        XCTAssertTrue(executedBox.value)
        XCTAssertEqual(undoMessage, "Undid last action (test_tool).")
        
        let finalCount = await journal.count
        XCTAssertEqual(finalCount, 0)
    }
    
    func testUndoJournalEmptyReturnsMessage() async throws {
        let journal = UndoJournal.shared
        await journal.clear()
        
        let msg = try await journal.undoLast()
        XCTAssertEqual(msg, "Nothing to undo.")
    }
    
    func testUndoToolExecutesLastJournalAction() async throws {
        let journal = UndoJournal.shared
        await journal.clear()
        
        let revertedBox = Box(false)
        await journal.register(toolName: "sample_tool") {
            revertedBox.value = true
        }
        
        let undoTool = UndoTool()
        let context = ToolExecutionContext(trustState: .trusted)
        let result = try await undoTool.execute(args: [:], context: context)
        
        XCTAssertTrue(result.success)
        XCTAssertTrue(revertedBox.value)
        XCTAssertTrue(result.message.contains("Undid last action (sample_tool)"))
    }
}
