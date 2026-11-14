import XCTest
import Foundation
import PearlCore
@testable import PearlMemory
@testable import PearlTools

final class VaultAndDreamTests: XCTestCase {
    var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultAndDreamTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() async throws {
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try await super.tearDown()
    }
    
    // MARK: - 1. VaultManager Frontmatter, Wikilinks, Read, List, Search
    
    func testVaultManagerFrontmatterWikilinksWriteReadListSearch() throws {
        let vault = VaultManager(vaultURL: tempDirectory)
        
        let writtenURL = try vault.writeNote(
            name: "ProjectAlpha",
            content: "This is the primary specification for Project Alpha and its modular architecture.",
            tags: ["agent-memory", "project", "architecture"],
            wikilinks: ["ArchitectureSpec", "TeamRoster"]
        )
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: writtenURL.path))
        XCTAssertEqual(writtenURL.pathExtension, "md")
        
        // Read Note
        let readContent = vault.readNote(name: "ProjectAlpha")
        XCTAssertNotNil(readContent)
        guard let note = readContent else { return }
        
        // Assert YAML frontmatter
        XCTAssertTrue(note.hasPrefix("---\n"), "Note must begin with YAML frontmatter")
        XCTAssertTrue(note.contains("title: ProjectAlpha"))
        XCTAssertTrue(note.contains("tags:\n  - agent-memory\n  - project\n  - architecture"))
        XCTAssertTrue(note.contains("date: "))
        
        // Assert content body
        XCTAssertTrue(note.contains("This is the primary specification for Project Alpha"))
        
        // Assert Wikilinks
        XCTAssertTrue(note.contains("## Links"))
        XCTAssertTrue(note.contains("- [[ArchitectureSpec]]"))
        XCTAssertTrue(note.contains("- [[TeamRoster]]"))
        
        // List Notes
        let notes = vault.listNotes()
        XCTAssertEqual(notes, ["ProjectAlpha.md"])
        
        // Search Notes (by content and by filename)
        let contentHits = vault.searchNotes(query: "modular")
        XCTAssertEqual(contentHits.count, 1)
        XCTAssertEqual(contentHits.first?.file, "ProjectAlpha.md")
        XCTAssertTrue(contentHits.first?.snippet.contains("modular") ?? false)
        
        let nameHits = vault.searchNotes(query: "Alpha")
        XCTAssertEqual(nameHits.count, 1)
        XCTAssertEqual(nameHits.first?.file, "ProjectAlpha.md")
    }
    
    // MARK: - 2. VaultManager Path-Traversal Rejection
    
    func testVaultManagerPathTraversalRejection() {
        let vault = VaultManager(vaultURL: tempDirectory)
        
        XCTAssertThrowsError(try vault.resolveAndSanitize(name: "../escape")) { error in
            XCTAssertEqual(error as? VaultError, VaultError.invalidNoteName("../escape"))
        }
        
        XCTAssertThrowsError(try vault.resolveAndSanitize(name: "sub/../../escape.md")) { error in
            XCTAssertEqual(error as? VaultError, VaultError.invalidNoteName("sub/../../escape.md"))
        }
        
        XCTAssertThrowsError(try vault.resolveAndSanitize(name: "/etc/passwd")) { error in
            XCTAssertEqual(error as? VaultError, VaultError.invalidNoteName("/etc/passwd"))
        }
        
        XCTAssertThrowsError(try vault.resolveAndSanitize(name: "~/secret.md")) { error in
            XCTAssertEqual(error as? VaultError, VaultError.invalidNoteName("~/secret.md"))
        }
        
        XCTAssertThrowsError(try vault.resolveAndSanitize(name: "   ")) { error in
            XCTAssertEqual(error as? VaultError, VaultError.invalidNoteName("   "))
        }
    }
    
    // MARK: - 3. VaultManager Empty Content & Note Not Found
    
    func testVaultManagerEmptyContentAndNotFound() {
        let vault = VaultManager(vaultURL: tempDirectory)
        
        XCTAssertThrowsError(try vault.writeNote(name: "BlankNote", content: "   \n\t  ")) { error in
            XCTAssertEqual(error as? VaultError, VaultError.emptyContent)
        }
        
        let nonExistent = vault.readNote(name: "NoSuchNote")
        XCTAssertNil(nonExistent)
    }
    
    // MARK: - 4. VaultManager Fact Synchronization
    
    func testVaultManagerSyncFactToVault() throws {
        let vault = VaultManager(vaultURL: tempDirectory)
        
        try vault.syncFactToVault(key: "preferred_ide", value: "Xcode")
        let firstRead = vault.readNote(name: "Memory/Facts.md")
        XCTAssertNotNil(firstRead)
        XCTAssertTrue(firstRead!.contains("- **preferred_ide**: Xcode"))
        
        try vault.syncFactToVault(key: "tea_choice", value: "Matcha")
        let secondRead = vault.readNote(name: "Memory/Facts.md")
        XCTAssertNotNil(secondRead)
        XCTAssertTrue(secondRead!.contains("- **preferred_ide**: Xcode"))
        XCTAssertTrue(secondRead!.contains("- **tea_choice**: Matcha"))
        
        let search = vault.searchNotes(query: "Matcha")
        XCTAssertEqual(search.count, 1)
        XCTAssertEqual(search.first?.file, "Memory/Facts.md")
    }
    
    // MARK: - 5. DreamEngine Insufficient Memories Error
    
    func testDreamEngineInsufficientMemoriesError() async {
        let vault = VaultManager(vaultURL: tempDirectory)
        let engine = DreamEngine(vaultManager: vault)
        
        // 0 memories
        do {
            _ = try await engine.synthesizeDream(extraFragments: [])
            XCTFail("Expected DreamError.insufficientMemories(0)")
        } catch let err as DreamError {
            XCTAssertEqual(err, DreamError.insufficientMemories(0))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        
        // 1 memory item
        do {
            _ = try await engine.synthesizeDream(extraFragments: ["Lone fragment without partner"])
            XCTFail("Expected DreamError.insufficientMemories(1)")
        } catch let err as DreamError {
            XCTAssertEqual(err, DreamError.insufficientMemories(1))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    // MARK: - 6. DreamEngine Synthesis Bridging Earliest & Recent Notes
    
    func testDreamEngineSynthesisBridgesEarliestAndRecentNotes() async throws {
        let vault = VaultManager(vaultURL: tempDirectory)
        
        // Write earliest note
        try vault.writeNote(
            name: "Research/KernelDesign",
            content: "We explored memory management algorithms and low-latency scheduling principles for kernel design.",
            tags: ["research"],
            wikilinks: []
        )
        
        // Sleep briefly to ensure distinct timestamps
        try await Task.sleep(nanoseconds: 20_000_000)
        
        // Write recent note
        try vault.writeNote(
            name: "Research/AgentScheduling",
            content: "Evaluating agent scheduling loops and memory management cache hit ratios in contemporary systems.",
            tags: ["research"],
            wikilinks: []
        )
        
        let engine = DreamEngine(vaultManager: vault)
        var comps = DateComponents()
        comps.year = 2023
        comps.month = 11
        comps.day = 14
        comps.hour = 12
        let testDate = Calendar.current.date(from: comps)!
        
        let dream = try await engine.synthesizeDream(date: testDate)
        
        XCTAssertEqual(dream.savedNotePath, "Dreams/2023-11-14.md")
        XCTAssertTrue(dream.title.contains("Dream Synthesis"))
        
        // Check bridging themes (both notes share "scheduling" and "memory")
        XCTAssertTrue(dream.sharedThemes.contains("scheduling") || dream.sharedThemes.contains("memory"))
        
        // Check source notes and narrative wikilinks
        XCTAssertTrue(dream.sourceNotes.contains("Research/KernelDesign"))
        XCTAssertTrue(dream.sourceNotes.contains("Research/AgentScheduling"))
        XCTAssertTrue(dream.bridgeNarrative.contains("[[Research/KernelDesign]]"))
        XCTAssertTrue(dream.bridgeNarrative.contains("[[Research/AgentScheduling]]"))
        
        // Verify note saved in vault
        let savedDreamContent = vault.readNote(name: "Dreams/2023-11-14.md")
        XCTAssertNotNil(savedDreamContent)
        guard let saved = savedDreamContent else { return }
        XCTAssertTrue(saved.contains("tags:\n  - dream\n  - synthesis"))
        XCTAssertTrue(saved.contains("[[Research/KernelDesign]]"))
        XCTAssertTrue(saved.contains("[[Research/AgentScheduling]]"))
    }
    
    // MARK: - 7. VaultListTool and VaultReadTool Execution
    
    func testVaultListAndReadTools() async throws {
        let vault = VaultManager(vaultURL: tempDirectory)
        try vault.writeNote(name: "Guides/GettingStarted", content: "Welcome to Pearl! Here is how to configure local tools.", tags: ["guide"])
        
        let listTool = VaultListTool(vaultManager: vault)
        let context = ToolExecutionContext()
        
        let listResult = try await listTool.execute(args: [:], context: context)
        XCTAssertTrue(listResult.success)
        XCTAssertTrue(listResult.message.contains("Guides/GettingStarted.md"))
        
        let readTool = VaultReadTool(vaultManager: vault)
        let readResult = try await readTool.execute(args: ["name": "Guides/GettingStarted"], context: context)
        XCTAssertTrue(readResult.success)
        XCTAssertTrue(readResult.message.contains("Welcome to Pearl!"))
        
        let notFoundResult = try await readTool.execute(args: ["name": "MissingGuide"], context: context)
        XCTAssertFalse(notFoundResult.success)
        XCTAssertTrue(notFoundResult.message.contains("not found"))
    }
    
    // MARK: - 8. VaultWriteTool and VaultSearchTool Execution with Undo
    
    func testVaultWriteAndSearchToolsWithUndo() async throws {
        let vault = VaultManager(vaultURL: tempDirectory)
        let journal = UndoJournal()
        let writeTool = VaultWriteTool(vaultManager: vault, undoJournal: journal)
        let searchTool = VaultSearchTool(vaultManager: vault)
        let context = ToolExecutionContext()
        
        let writeResult = try await writeTool.execute(
            args: [
                "name": "MeetingNotes",
                "content": "Discussed distributed vector index integration and graph caching.",
                "tags": "work, engineering",
                "wikilinks": "ProjectRoadmap"
            ],
            context: context
        )
        XCTAssertTrue(writeResult.success)
        XCTAssertNotNil(vault.readNote(name: "MeetingNotes"))
        
        // Search Tool
        let searchResult = try await searchTool.execute(args: ["query": "distributed"], context: context)
        XCTAssertTrue(searchResult.success)
        XCTAssertTrue(searchResult.message.contains("MeetingNotes.md"))
        
        // Undo Rollback removes the written note
        let undoMsg = try await journal.undoLast()
        XCTAssertTrue(undoMsg.contains("vault_write"))
        XCTAssertNil(vault.readNote(name: "MeetingNotes"), "Undoing vault_write must delete created note")
    }
    
    // MARK: - 9. OutputFileTool Atomic Write, Extension Check, and Undo Rollback
    
    func testOutputFileToolAtomicWriteAllowedExtensionsAndUndo() async throws {
        let outputDir = tempDirectory.appendingPathComponent("PearlOutput", isDirectory: true)
        let journal = UndoJournal()
        let tool = OutputFileTool(outputDirectory: outputDir, undoJournal: journal)
        let context = ToolExecutionContext()
        
        // Test Allowed Extensions: .md, .json, .csv, .txt, .html
        let validCases = [
            ("report.md", "# Markdown Report"),
            ("data.json", "{\"status\": \"ok\", \"count\": 42}"),
            ("metrics.csv", "id,score\n1,98.5\n2,99.1"),
            ("notes.txt", "Plain text summary"),
            ("dashboard.html", "<html><body>Active</body></html>")
        ]
        
        for (filename, content) in validCases {
            let res = try await tool.execute(args: ["filename": filename, "content": content], context: context)
            XCTAssertTrue(res.success, "Writing \(filename) should succeed")
            let fileURL = outputDir.appendingPathComponent(filename)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
            let readBack = try? String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertEqual(readBack, content)
        }
        
        // Disallow dangerous extensions: .sh, .exe, .py
        let invalidExtensions = ["script.sh", "binary.exe", "exploit.py"]
        for badFile in invalidExtensions {
            let res = try await tool.execute(args: ["filename": badFile, "content": "malicious"], context: context)
            XCTAssertFalse(res.success, "Extension for \(badFile) must be rejected")
            XCTAssertTrue(res.message.contains("Disallowed file extension"))
        }
        
        // Disallow path traversal and slashes
        let traversalCases = ["../escape.md", "sub/folder/file.json", "dir\\nested.txt"]
        for badPath in traversalCases {
            let res = try await tool.execute(args: ["filename": badPath, "content": "escape"], context: context)
            XCTAssertFalse(res.success, "Traversal \(badPath) must be rejected")
        }
        
        // Test Undo Rollback deletes newly created file
        let createdFile = outputDir.appendingPathComponent("dashboard.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdFile.path))
        
        let undoResult = try await journal.undoLast()
        XCTAssertTrue(undoResult.contains("write_output_file"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: createdFile.path),
            "Undo should remove the newly created file"
        )
    }
}
