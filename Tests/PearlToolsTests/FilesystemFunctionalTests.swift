import Darwin
import Foundation
import XCTest
@testable import PearlCore
@testable import PearlTools

/// Phase 7 Mandatory Filesystem, Routing, Clarification, Symlink, Undo & E2E Acceptance Suite.
final class FilesystemFunctionalTests: XCTestCase {

    private var rootTempDir: URL!
    private var approvedDesktop: URL!
    private var approvedDocs: URL!
    private var approvedProjects: URL!
    private var outsideDir: URL!
    private var validator: FolderAllowlistValidator!
    private var permissionManager: FilesystemPermissionManager!
    private var testRegistry: ToolRegistry!

    override func setUp() async throws {
        try await super.setUp()
        TaintTracker.shared.reset()
        await UndoJournal.shared.clear()

        let unique = "PearlFSFuncTests_\(UUID().uuidString)"
        let rawTemp = FileManager.default.temporaryDirectory.appendingPathComponent(unique)
        try FileManager.default.createDirectory(at: rawTemp, withIntermediateDirectories: true)
        // Resolve /var -> /private/var canonically for macOS assertions
        rootTempDir = URL(fileURLWithPath: rawTemp.resolvingSymlinksInPath().path)

        approvedDesktop = rootTempDir.appendingPathComponent("Desktop")
        approvedDocs = rootTempDir.appendingPathComponent("Documents")
        approvedProjects = rootTempDir.appendingPathComponent("Projects")
        outsideDir = rootTempDir.appendingPathComponent("Outside")

        for dir in [approvedDesktop!, approvedDocs!, approvedProjects!, outsideDir!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let bookmarksURL = rootTempDir.appendingPathComponent("folder_bookmarks.json")
        permissionManager = FilesystemPermissionManager(
            bookmarksFileURL: bookmarksURL,
            allowedFoldersOverride: [approvedDesktop.path, approvedDocs.path, approvedProjects.path]
        )
        validator = FolderAllowlistValidator(
            allowedFolders: [approvedDesktop.path, approvedDocs.path, approvedProjects.path],
            permissionManager: permissionManager
        )

        testRegistry = ToolRegistry()
        PearlToolsRegistry.registerAll(into: testRegistry, catalog: .shared)
        // Override filesystem tools in our isolated registry to point strictly at temp allowlisted folders
        testRegistry.register(CreateDirectoryTool(validator: validator))
        testRegistry.register(ListDirectoryTool(validator: validator))
        testRegistry.register(RenameFileTool(validator: validator))
        testRegistry.register(TrashFileTool(validator: validator))
        testRegistry.register(SearchFilesTool(validator: validator))
        testRegistry.register(ReadFileSafeTool(validator: validator))
        testRegistry.register(CopyFileTool(validator: validator))
        testRegistry.register(MoveFileTool(validator: validator))

        CentralToolCatalog.shared.registerAll(PearlToolsRegistry.allTools())
    }

    override func tearDown() async throws {
        await UndoJournal.shared.clear()
        TaintTracker.shared.reset()
        if let rootTempDir {
            try? FileManager.default.removeItem(at: rootTempDir)
        }
        try await super.tearDown()
    }

    private func makePipeline() -> AssistantPipeline {
        return AssistantPipeline(
            router: DeterministicRouter(),
            toolRegistry: testRegistry,
            policyEngine: PolicyEngine(),
            toolExecutor: ModelToolExecutor(registry: testRegistry),
            fallbackChain: FallbackChain(pccEnabled: false),
            sessionManager: SessionManager(),
            referenceResolver: ContextReferenceResolver()
        )
    }

    // MARK: - Scenario 1 & 2: Create Directory in Desktop / Documents Equivalents

    func testScenario01_CreateFolderInApprovedDesktopViaPipeline() async throws {
        let pipeline = makePipeline()
        let target = approvedDesktop.appendingPathComponent("Pearl").path
        let req = AssistantRequest(
            utterance: "Create a folder called Pearl inside \(approvedDesktop.path)",
            origin: .cli,
            userConfirmed: true
        )

        let resp = await pipeline.process(request: req)
        XCTAssertTrue(resp.success, "Expected pipeline create_directory success: \(resp.responseText)")

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: target, isDirectory: &isDir) && isDir.boolValue)
    }

    func testScenario02_CreateFolderInApprovedDocumentsViaTool() async throws {
        let tool = CreateDirectoryTool(validator: validator)
        let target = approvedDocs.appendingPathComponent("Experiments").path
        let res = try await tool.execute(args: ["path": target], context: ToolExecutionContext())
        XCTAssertTrue(res.success, res.message)
        XCTAssertEqual(res.errorCode, .completed)
        XCTAssertEqual(res.canonicalPath, target)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: target, isDirectory: &isDir) && isDir.boolValue)
    }

    // MARK: - Scenario 3: Tilde Expansion Verification (Without Mutating User Home)

    func testScenario03_TildeExpansionCanonicalizesHomeReference() throws {
        let rawPath = "~/Desktop/PearlUnitTestNonExistent_\(UUID().uuidString)"
        let resolved = try FolderAllowlistValidator().resolvePath(rawPath)
        let expectedPrefix = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/Desktop/"
        XCTAssertTrue(resolved.hasPrefix(expectedPrefix), "Expected expanded home prefix \(expectedPrefix), got \(resolved)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved))
    }

    // MARK: - Scenario 4 & 13: Recursive Create + Safe Empty-Only Recursive Undo

    func testScenario04And13_RecursiveCreateAndEmptyOnlyUndo() async throws {
        let tool = CreateDirectoryTool(validator: validator)
        let nested = approvedDocs.appendingPathComponent("Level1/Level2/Level3").path

        let res = try await tool.execute(
            args: ["path": nested, "recursive": "true"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(res.success, res.message)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested, isDirectory: &isDir) && isDir.boolValue)

        // Add a file inside Level3 -> undo MUST refuse safely rather than deleting user data
        let childFile = approvedDocs.appendingPathComponent("Level1/Level2/Level3/keep.txt")
        try "important".write(to: childFile, atomically: true, encoding: .utf8)

        if let undo = res.undoAction {
            do {
                try await undo()
                XCTFail("Undo should refuse when directory is non-empty")
            } catch {
                // Expected SafeUndoError.nonEmptyDirectory
                XCTAssertTrue(FileManager.default.fileExists(atPath: childFile.path))
            }

            // Now remove file and retry undo -> Level3, Level2, Level1 all removed while approvedDocs stays intact
            try FileManager.default.removeItem(at: childFile)
            try await undo()

            XCTAssertFalse(FileManager.default.fileExists(atPath: approvedDocs.appendingPathComponent("Level1").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: approvedDocs.path))
        } else {
            XCTFail("CreateDirectoryTool should attach a safe undo action")
        }
    }

    // MARK: - Scenario 5: Ambiguous Destination Clarification & Multi-Turn Resolution

    func testScenario05_AmbiguousDestinationAsksClarificationAndDoesNotGuess() async throws {
        let pipeline = makePipeline()
        let sessionID = UUID().uuidString

        let turn1 = await pipeline.process(request: AssistantRequest(
            utterance: "Create a folder called Research.",
            origin: .cli,
            sessionID: sessionID
        ))
        XCTAssertTrue(turn1.success)
        XCTAssertTrue(turn1.needsClarification)
        XCTAssertEqual(
            turn1.responseText,
            "Where should I create it: Desktop, Documents, Downloads or Projects?"
        )

        // Follow-up providing explicit approved folder path inside tempDesktop
        let turn2 = await pipeline.process(request: AssistantRequest(
            utterance: approvedDesktop.path,
            origin: .cli,
            sessionID: sessionID,
            userConfirmed: true
        ))
        XCTAssertTrue(turn2.success, turn2.responseText)

        let expectedPath = approvedDesktop.appendingPathComponent("Research").path
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedPath, isDirectory: &isDir) && isDir.boolValue)
    }

    // MARK: - Scenario 6: Duplicate Existing Folder & create_if_missing Idempotency

    func testScenario06_DuplicateExistingFolderVsCreateIfMissing() async throws {
        let tool = CreateDirectoryTool(validator: validator)
        let target = approvedDesktop.appendingPathComponent("ExistingFolder")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("keep.txt")
        try "data".write(to: sentinel, atomically: true, encoding: .utf8)

        let failRes = try await tool.execute(
            args: ["path": target.path, "create_if_missing": "false"],
            context: ToolExecutionContext()
        )
        XCTAssertFalse(failRes.success)
        XCTAssertEqual(failRes.errorCode, .alreadyExists)

        let idempotentRes = try await tool.execute(
            args: ["path": target.path, "create_if_missing": "true"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(idempotentRes.success, idempotentRes.message)
        XCTAssertNil(idempotentRes.undoAction, "Idempotent no-op should NOT attach destructive undo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    // MARK: - Scenario 7: Existing File Collision

    func testScenario07_ExistingFileAtTargetIsNotOverwritten() async throws {
        let tool = CreateDirectoryTool(validator: validator)
        let filePath = approvedDesktop.appendingPathComponent("collision.txt")
        try "preserve me".write(to: filePath, atomically: true, encoding: .utf8)

        let res = try await tool.execute(
            args: ["path": filePath.path, "create_if_missing": "true"],
            context: ToolExecutionContext()
        )
        XCTAssertFalse(res.success)
        XCTAssertEqual(res.errorCode, .alreadyExists)
        XCTAssertEqual(try String(contentsOf: filePath, encoding: .utf8), "preserve me")
    }

    // MARK: - Scenario 8: Missing Parent With recursive = false

    func testScenario08_MissingParentFailsWhenNonRecursive() async throws {
        let tool = CreateDirectoryTool(validator: validator)
        let target = approvedDesktop.appendingPathComponent("NoSuchParent/Child").path

        let res = try await tool.execute(
            args: ["path": target, "recursive": "false"],
            context: ToolExecutionContext()
        )
        XCTAssertFalse(res.success)
        XCTAssertEqual(res.errorCode, .parentMissing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    // MARK: - Scenario 9: Outside Approved Folders Blocked

    func testScenario09_OutsideApprovedFoldersBlocked() async throws {
        let tool = CreateDirectoryTool(validator: validator)
        let target = outsideDir.appendingPathComponent("Unapproved").path

        let res = try await tool.execute(args: ["path": target], context: ToolExecutionContext())
        XCTAssertFalse(res.success)
        XCTAssertEqual(res.errorCode, .outsideApprovedFolders)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    // MARK: - Scenario 10 & 11: Path Traversal & Protected System/Credential Paths Blocked

    func testScenario10And11_PathTraversalAndSystemCredentialPathsBlocked() async throws {
        let tool = CreateDirectoryTool(validator: validator)

        let traversal = try await tool.execute(
            args: ["path": "\(approvedDesktop.path)/../../Outside/Bypass"],
            context: ToolExecutionContext()
        )
        XCTAssertFalse(traversal.success)
        XCTAssertEqual(traversal.errorCode, .invalidArguments)

        for sensitive in ["/etc/pearl_test", "~/.ssh/pearl_test", "~/.aws/pearl_test", "/System/Library/pearl_test"] {
            let res = try await tool.execute(args: ["path": sensitive], context: ToolExecutionContext())
            XCTAssertFalse(res.success, "Sensitive path \(sensitive) must be rejected")
            XCTAssertEqual(res.errorCode, .permissionDenied, "Unexpected errorCode for \(sensitive)")
        }
    }

    // MARK: - Scenario 12: Symlink Escape Blocked Across Filesystem Tools

    func testScenario12_SymlinkEscapeBlockedAcrossAllFilesystemTools() async throws {
        let symlinkInsideAllowed = approvedDesktop.appendingPathComponent("escape_link")
        try FileManager.default.createSymbolicLink(atPath: symlinkInsideAllowed.path, withDestinationPath: outsideDir.path)

        let escapeChild = symlinkInsideAllowed.appendingPathComponent("escaped_folder").path
        let createRes = try await CreateDirectoryTool(validator: validator).execute(
            args: ["path": escapeChild],
            context: ToolExecutionContext()
        )
        XCTAssertFalse(createRes.success)
        XCTAssertEqual(createRes.errorCode, .outsideApprovedFolders)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideDir.appendingPathComponent("escaped_folder").path))

        let listRes = try await ListDirectoryTool(validator: validator).execute(
            args: ["path": symlinkInsideAllowed.path],
            context: ToolExecutionContext()
        )
        XCTAssertFalse(listRes.success)
        XCTAssertEqual(listRes.errorCode, .outsideApprovedFolders)

        let trashRes = try await TrashFileTool(validator: validator).execute(
            args: ["path": escapeChild],
            context: ToolExecutionContext()
        )
        XCTAssertFalse(trashRes.success)
    }

    // MARK: - Scenario 14 & 15: List Directory Filtering, Clamping & Home Recursive Guard

    func testScenario14And15_ListDirectoryFilteringAndHomeRecursiveGuard() async throws {
        try FileManager.default.createDirectory(at: approvedDocs.appendingPathComponent("AlphaDir"), withIntermediateDirectories: true)
        try "pdf".write(to: approvedDocs.appendingPathComponent("report.pdf"), atomically: true, encoding: .utf8)
        try "txt".write(to: approvedDocs.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let listTool = ListDirectoryTool(validator: validator)

        let foldersOnly = try await listTool.execute(
            args: ["path": approvedDocs.path, "filter": "folders"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(foldersOnly.success, foldersOnly.message)
        XCTAssertTrue(foldersOnly.message.contains("AlphaDir"))
        XCTAssertFalse(foldersOnly.message.contains("report.pdf"))

        let pdfFilter = try await listTool.execute(
            args: ["path": approvedDocs.path, "filter": "pdf"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(pdfFilter.success)
        XCTAssertTrue(pdfFilter.message.contains("report.pdf"))
        XCTAssertFalse(pdfFilter.message.contains("notes.txt"))

        // Home directory recursive scan MUST always fail safely
        let homePerm = FolderAllowlistValidator(allowedFolders: [NSHomeDirectory()])
        let homeGuard = try await ListDirectoryTool(validator: homePerm).execute(
            args: ["path": NSHomeDirectory(), "recursive": "true"],
            context: ToolExecutionContext()
        )
        XCTAssertFalse(homeGuard.success)
        XCTAssertEqual(homeGuard.errorCode, .permissionDenied)
    }

    // MARK: - Scenario 16: Rename File & Folder + Collision + Undo

    func testScenario16_RenameFolderCollisionAndUndo() async throws {
        let research = approvedDesktop.appendingPathComponent("Research")
        let archive = approvedDesktop.appendingPathComponent("Archive")
        let blocker = approvedDesktop.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: research, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)

        let renameTool = RenameFileTool(validator: validator)

        // Collision fails cleanly
        let collision = try await renameTool.execute(
            args: ["source": research.path, "destination": "Existing"],
            context: ToolExecutionContext()
        )
        XCTAssertFalse(collision.success)
        XCTAssertEqual(collision.errorCode, .alreadyExists)

        // Rename Research -> Archive
        let ok = try await renameTool.execute(
            args: ["source": research.path, "destination": "Archive"],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(ok.success, ok.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: research.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        // Undo restores Research
        if let undo = ok.undoAction {
            try await undo()
            XCTAssertTrue(FileManager.default.fileExists(atPath: research.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        } else {
            XCTFail("Expected undoAction on RenameFileTool")
        }

        // Approved root rename refused
        let rootDeny = try await renameTool.execute(
            args: ["source": approvedDesktop.path, "destination": "DesktopRenamed"],
            context: ToolExecutionContext()
        )
        XCTAssertFalse(rootDeny.success)
        XCTAssertEqual(rootDeny.errorCode, .permissionDenied)
    }

    // MARK: - Scenario 17: Move File Into Directory + Pipeline Confirmation Gate + Undo

    func testScenario17_MoveFileIntoDirectoryWithConfirmationAndUndo() async throws {
        let srcFile = approvedDesktop.appendingPathComponent("draft.md")
        let targetDir = approvedDesktop.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try "# Draft".write(to: srcFile, atomically: true, encoding: .utf8)

        let pipeline = makePipeline()
        let reqUnconfirmed = AssistantRequest(
            utterance: "Move \(srcFile.path) into \(targetDir.path)",
            origin: .cli,
            userConfirmed: false
        )
        let first = await pipeline.process(request: reqUnconfirmed)
        XCTAssertTrue(first.requiresConfirmation, "move_file requires confirmation in pipeline")
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcFile.path))

        let reqConfirmed = AssistantRequest(
            utterance: "Move \(srcFile.path) into \(targetDir.path)",
            origin: .cli,
            userConfirmed: true,
            freshConfirmationArgs: first.confirmationArguments
        )
        let second = await pipeline.process(request: reqConfirmed)
        XCTAssertTrue(second.success, second.responseText)

        let movedFile = targetDir.appendingPathComponent("draft.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: srcFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedFile.path))

        // Undo via UndoJournal
        let undoMsg = try await UndoJournal.shared.undoLast()
        XCTAssertTrue(undoMsg.contains("Undid"), undoMsg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedFile.path))
    }

    // MARK: - Scenario 18: Trash File / Folder + Protected Reject + Undo Restore

    func testScenario18_TrashFileMovesToTrashAndUndoRestores() async throws {
        let disposable = approvedDocs.appendingPathComponent("trash_me_\(UUID().uuidString).txt")
        try "temporary note".write(to: disposable, atomically: true, encoding: .utf8)

        let trashTool = TrashFileTool(validator: validator)
        let res = try await trashTool.execute(
            args: ["path": disposable.path],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(res.success, res.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: disposable.path))

        // Immediately undo to restore out of Trash so host Trash stays clean
        if let undo = res.undoAction {
            try await undo()
            XCTAssertTrue(FileManager.default.fileExists(atPath: disposable.path))
            XCTAssertEqual(try String(contentsOf: disposable, encoding: .utf8), "temporary note")
        } else {
            XCTFail("TrashFileTool should attach reversible undo closure")
        }

        // Reject trashing approved root & sensitive files
        let rootTrash = try await trashTool.execute(args: ["path": approvedDocs.path], context: ToolExecutionContext())
        XCTAssertFalse(rootTrash.success)
        XCTAssertEqual(rootTrash.errorCode, .permissionDenied)

        let sshTrash = try await trashTool.execute(args: ["path": "~/.ssh/id_rsa"], context: ToolExecutionContext())
        XCTAssertFalse(sshTrash.success)
        XCTAssertEqual(sshTrash.errorCode, .permissionDenied)
    }

    // MARK: - Scenario 19: Search Files Extension-Only Search

    func testScenario19_SearchFilesExtensionOnlyMatch() async throws {
        try "pdf1".write(to: approvedDocs.appendingPathComponent("invoice_2026.pdf"), atomically: true, encoding: .utf8)
        try "txt1".write(to: approvedDocs.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let searchTool = SearchFilesTool(validator: validator)
        let res = try await searchTool.execute(
            args: ["query": "", "extension": "pdf", "folder": approvedDocs.path],
            context: ToolExecutionContext()
        )
        XCTAssertTrue(res.success, res.message)
        XCTAssertTrue(res.message.contains("invoice_2026.pdf"))
        XCTAssertFalse(res.message.contains("notes.txt"))
    }

    // MARK: - Scenario 20: Multi-Folder Creation Plan Through AssistantPipeline

    func testScenario20_MultiFolderCreationViaAssistantPipeline() async throws {
        let pipeline = makePipeline()
        let req = AssistantRequest(
            utterance: "Create three folders named Backend, Frontend and Documentation inside \(approvedProjects.path)",
            origin: .cli,
            userConfirmed: true
        )
        let resp = await pipeline.process(request: req)
        XCTAssertTrue(resp.success, resp.responseText)

        for name in ["Backend", "Frontend", "Documentation"] {
            let p = approvedProjects.appendingPathComponent(name).path
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue, "Expected \(name) folder at \(p)")
        }
    }

    // MARK: - Phase 3: NL Routing Grammar, Negation & Meta-Question Guards

    func testPhase3_DeterministicFilesystemGrammarAndNegationGuards() {
        let router = DeterministicRouter()

        let desktopResearch = router.resolve(utterance: "Create Research on my Desktop.")
        XCTAssertEqual(desktopResearch?.toolName, "create_directory")
        XCTAssertEqual(desktopResearch?.arguments["path"], "~/Desktop/Research")

        let docsExperiments = router.resolve(utterance: "Make a folder named Experiments inside Documents.")
        XCTAssertEqual(docsExperiments?.toolName, "create_directory")
        XCTAssertEqual(docsExperiments?.arguments["path"], "~/Documents/Experiments")

        let multi = router.resolve(utterance: "Create three folders named Backend, Frontend and Documentation inside Projects.")
        XCTAssertEqual(multi?.planSteps?.count, 3)

        let listDesktop = router.resolve(utterance: "List the folders on my Desktop.")
        XCTAssertEqual(listDesktop?.toolName, "list_directory")
        XCTAssertEqual(listDesktop?.arguments["path"], "~/Desktop")
        XCTAssertEqual(listDesktop?.arguments["filter"], "folders")

        let pdfDownloads = router.resolve(utterance: "Find all PDF files in Downloads.")
        XCTAssertEqual(pdfDownloads?.toolName, "search_files")
        XCTAssertEqual(pdfDownloads?.arguments["extension"], "pdf")
        XCTAssertEqual(pdfDownloads?.arguments["folder"], "~/Downloads")

        // Negations & meta-questions MUST NOT trigger destructive routes
        XCTAssertNil(router.resolve(utterance: "Don't create a folder on Desktop"))
        XCTAssertNil(router.resolve(utterance: "Cancel creating Research folder"))
        XCTAssertNil(router.resolve(utterance: "Never trash my notes"))
        XCTAssertNil(router.resolve(utterance: "Can you create folders on macOS?"))
        XCTAssertNil(router.resolve(utterance: "How do I delete a folder?"))
    }

    // MARK: - Phase 2.6: FilesystemPermissionManager Dynamic Add / Revalidate / Remove

    func testPhase2_6_FilesystemPermissionManagerAddRevalidateAndRemove() throws {
        let dynamicExtra = rootTempDir.appendingPathComponent("ExtraAuthorized")
        try FileManager.default.createDirectory(at: dynamicExtra, withIntermediateDirectories: true)

        XCTAssertTrue(permissionManager.approvedFolderPaths().contains(approvedDesktop.path))
        XCTAssertFalse(permissionManager.approvedFolderPaths().contains(dynamicExtra.path))

        let added = try permissionManager.addApprovedFolder(url: dynamicExtra)
        XCTAssertEqual(added.canonicalPath, dynamicExtra.path)
        XCTAssertEqual(added.status, .accessible)
        XCTAssertTrue(permissionManager.approvedFolderPaths().contains(dynamicExtra.path))

        let revalidated = permissionManager.revalidateBookmarks()
        XCTAssertTrue(revalidated.contains(where: { $0.canonicalPath == dynamicExtra.path && $0.status == .accessible }))

        let childPath = dynamicExtra.appendingPathComponent("sub").path
        switch validator.validate(path: childPath) {
        case .success(let resolved):
            XCTAssertEqual(resolved, childPath)
        case .failure(let err):
            XCTFail("Expected newly authorized folder child to pass validation: \(err)")
        }

        permissionManager.removeApprovedFolder(path: dynamicExtra.path)
        XCTAssertFalse(permissionManager.approvedFolderPaths().contains(dynamicExtra.path))

        switch validator.validate(path: childPath) {
        case .success:
            XCTFail("Removed folder child must be rejected after removal")
        case .failure(let err):
            XCTAssertEqual(err, .outsideAllowedFolders(path: childPath))
        }
    }
}
