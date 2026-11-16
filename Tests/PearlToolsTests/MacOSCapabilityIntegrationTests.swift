import AppKit
import Foundation
import XCTest
@testable import PearlCore
@testable import PearlTools

/// Phase 5 Basic macOS Task Reliability & Isolated Local Integration Tests.
final class MacOSCapabilityIntegrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("PearlCapTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        tempDir = raw
        await UndoJournal.shared.clear()
        TaintTracker.shared.reset()
    }

    override func tearDown() async throws {
        await UndoJournal.shared.clear()
        TaintTracker.shared.reset()
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Reminders (Create / List / Complete / Undo)

    func testReminderToolCreateListCompleteAndUndo() async throws {
        let storeURL = tempDir.appendingPathComponent("reminders.json")
        let tool = ReminderTool(localStoreURL: storeURL)

        let createRes = try await tool.execute(
            args: ["action": "create", "title": "Review Pearl v3.3 architecture"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(createRes.success, createRes.message)
        XCTAssertTrue(createRes.message.contains("Review Pearl v3.3 architecture"))

        let listRes1 = try await tool.execute(
            args: ["action": "list"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(listRes1.success, listRes1.message)
        XCTAssertTrue(listRes1.message.contains("Review Pearl v3.3 architecture"))

        let completeRes = try await tool.execute(
            args: ["action": "complete", "title": "Review Pearl v3.3 architecture"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(completeRes.success, completeRes.message)
        XCTAssertTrue(completeRes.message.lowercased().contains("completed"))

        // Undo completion -> reminder becomes incomplete again
        if let undoComplete = completeRes.undoAction {
            try await undoComplete()
            let listAfterUndoComplete = try await tool.execute(args: ["action": "list"], context: ToolExecutionContext())
            XCTAssertTrue(listAfterUndoComplete.message.contains("Review Pearl v3.3 architecture"))
        } else {
            XCTFail("Completing a reminder should attach an undo closure")
        }

        // Undo creation -> reminder removed cleanly
        if let undoCreate = createRes.undoAction {
            try await undoCreate()
            let listAfterUndoCreate = try await tool.execute(args: ["action": "list"], context: ToolExecutionContext())
            XCTAssertFalse(listAfterUndoCreate.message.contains("Review Pearl v3.3 architecture"))
        } else {
            XCTFail("Creating a reminder should attach an undo closure")
        }
    }

    // MARK: - Tasks (Create / List / Complete / Delete)

    func testTaskToolsLifecycleInIsolatedTestStorage() async throws {
        let createTool = CreateTaskTool()
        let listTool = ListTasksTool()
        let completeTool = CompleteTaskTool()
        let deleteTool = DeleteTaskTool()

        let createRes = try await createTool.execute(
            args: ["title": "Prepare v3.3 release notes", "priority": "high"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(createRes.success, createRes.message)

        let listRes = try await listTool.execute(args: ["status": "pending"], context: ToolExecutionContext())
        XCTAssertTrue(listRes.success, listRes.message)
        XCTAssertTrue(listRes.message.contains("Prepare v3.3 release notes"))

        let completeRes = try await completeTool.execute(
            args: ["title": "Prepare v3.3 release notes"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(completeRes.success, completeRes.message)

        let deleteBlocked = try await deleteTool.execute(
            args: ["title": "Prepare v3.3 release notes"],
            context: ToolExecutionContext()
        )
        XCTAssertFalse(deleteBlocked.success, "Deleting task without confirm='true' must require confirmation")

        let deleteRes = try await deleteTool.execute(
            args: ["title": "Prepare v3.3 release notes", "confirm": "true"],
            context: ToolExecutionContext(userConfirmed: true)
        )
        XCTAssertTrue(deleteRes.success, deleteRes.message)
    }

    // MARK: - Calendar Local Store Isolation

    func testCalendarLocalStorePersistenceAndRemoval() async throws {
        let storeURL = tempDir.appendingPathComponent("calendar.json")
        let store = CalendarLocalStore(localStoreURL: storeURL)
        let now = Date()
        let event = LocalCalendarEvent(
            title: "Architecture Sync",
            startDate: now,
            endDate: now.addingTimeInterval(1800)
        )
        await store.saveEvent(event)

        let loaded = await store.loadEvents()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "Architecture Sync")

        await store.removeEvent(id: event.id)
        let remaining = await store.loadEvents()
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - Clipboard Secret Redaction & Safe Round-Trip Undo

    func testSecretRedactorMasksSensitiveTokens() {
        let sample = """
        api_key=super_secret_token_987654
        anthropic=sk-ant-api03-1234567890abcdefghijklmnop
        github=ghp_1234567890abcdefghijklmnopqrstuvwxyz
        bearer=Bearer mySecretJwtBearerToken12345
        """
        let result = SecretRedactor.shared.redact(text: sample)
        XCTAssertGreaterThanOrEqual(result.redactionCount, 3)
        XCTAssertFalse(result.text.contains("super_secret_token_987654"))
        XCTAssertFalse(result.text.contains("sk-ant-api03-1234567890abcdefghijklmnop"))
        XCTAssertFalse(result.text.contains("ghp_1234567890abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(result.text.contains("[REDACTED"))
    }

    func testClipboardWriteReadRedactsAndUndoRestoresSafely() async throws {
        // Only run mutating pasteboard test when pasteboard holds plain string (or is empty) so rich user items aren't disturbed
        let shouldSkip: Bool = await MainActor.run {
            let items = NSPasteboard.general.pasteboardItems ?? []
            if items.isEmpty { return false }
            return !items.allSatisfy { $0.types.contains(.string) && $0.types.count <= 2 }
        }
        guard !shouldSkip else { return }

        let priorText = await MainActor.run { NSPasteboard.general.string(forType: .string) }
        defer {
            Task { @MainActor in
                NSPasteboard.general.clearContents()
                if let priorText {
                    NSPasteboard.general.setString(priorText, forType: .string)
                }
            }
        }

        let writeTool = WriteClipboardTool()
        let readTool = ReadClipboardTool()

        let writeRes = try await writeTool.execute(
            args: ["text": "token: ghp_1234567890abcdefghijklmnopqrstuvwxyz safe-tail"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(writeRes.success, writeRes.message)

        let readRes = try await readTool.execute(args: [:], context: ToolExecutionContext())
        XCTAssertTrue(readRes.success, readRes.message)
        XCTAssertTrue(readRes.message.contains("[REDACTED_GITHUB_TOKEN]"))
        XCTAssertTrue(readRes.message.contains("safe-tail"))
        XCTAssertFalse(readRes.message.contains("ghp_1234567890abcdefghijklmnopqrstuvwxyz"))

        if let undo = writeRes.undoAction {
            try await undo()
            let restored = await MainActor.run { NSPasteboard.general.string(forType: .string) }
            XCTAssertEqual(restored, priorText)
        } else {
            XCTFail("WriteClipboardTool must attach an undo closure")
        }
    }

    // MARK: - System Inspection Tools (Non-Destructive Real Host Checks)

    func testSystemInspectionToolsExecuteCleanly() async throws {
        let batteryRes = try await BatteryTool().execute(args: [:], context: ToolExecutionContext())
        XCTAssertTrue(batteryRes.success, batteryRes.message)

        let volumeRes = try await VolumeTool().execute(args: ["action": "get"], context: ToolExecutionContext())
        XCTAssertTrue(volumeRes.success, volumeRes.message)

        let displayRes = try await GetDisplayInfoTool().execute(args: [:], context: ToolExecutionContext())
        XCTAssertTrue(displayRes.success, displayRes.message)

        let frontRes = try await FrontmostAppTool().execute(args: [:], context: ToolExecutionContext())
        XCTAssertTrue(frontRes.success, frontRes.message)

        let windowsRes = try await ListWindowsTool().execute(args: [:], context: ToolExecutionContext())
        XCTAssertTrue(windowsRes.success, windowsRes.message)

        // Missing app fails honestly without launching anything
        let missingApp = try await AppTool().execute(
            args: ["app": "NonExistentPearlTestApp_99999"],
            context: ToolExecutionContext()
        )
        XCTAssertFalse(missingApp.success)
    }

    // MARK: - Phase 4: Full Runtime Catalog <-> ToolRegistry Sync Across PearlCore + PearlTools

    func testFullRuntimeToolCatalogAndRegistryConsistency() {
        let fullRegistry = ToolRegistry()
        let fullCatalog = CentralToolCatalog()
        PearlToolsRegistry.bootstrapAllTools(into: fullRegistry, catalog: fullCatalog)

        let report = fullCatalog.auditConsistency(against: fullRegistry)
        XCTAssertTrue(report.isHealthy, "Catalog consistency unhealthy: missingReg=\(report.missingFromToolRegistry) missingCat=\(report.missingFromCatalog) metaNoImpl=\(report.metadataWithoutImplementation) tier=\(report.tierMismatches) desc=\(report.descriptorMismatches) mcp=\(report.mcpViolations)")
        XCTAssertTrue(report.missingFromToolRegistry.isEmpty, "Missing from ToolRegistry: \(report.missingFromToolRegistry)")
        XCTAssertTrue(report.missingFromCatalog.isEmpty, "Missing from Catalog: \(report.missingFromCatalog)")
        XCTAssertTrue(report.tierMismatches.isEmpty, "Tier mismatches: \(report.tierMismatches)")
        XCTAssertTrue(report.descriptorMismatches.isEmpty, "Descriptor mismatches: \(report.descriptorMismatches)")
        XCTAssertTrue(report.mcpViolations.isEmpty, "MCP tier violations: \(report.mcpViolations)")
    }
}
