import XCTest
import Foundation
import PearlCore
@testable import PearlMemory

final class MemoryV3Tests: XCTestCase {
    var tempDirectory: URL!
    var store: MemoryStore!
    
    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PearlMemoryTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = try MemoryStore(baseDirectory: tempDirectory)
    }
    
    override func tearDown() async throws {
        if let dir = tempDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }
    
    // MARK: - Test 1: The 6 Required Memory Classes
    
    func testSixMemoryClasses() async throws {
        let items: [MemoryItem] = [
            MemoryItem(
                id: "profile_1",
                category: .profile,
                content: "Hardware: MacBook Neo with Apple Silicon A18 Pro",
                source: "user",
                provenance: "user_profile",
                confidence: 1.0,
                sensitivity: .personal,
                userApproved: true
            ),
            MemoryItem(
                id: "semantic_1",
                category: .semantic,
                content: "SQLite FTS5 uses BM25 ranking algorithm by default",
                source: "user",
                provenance: "docs",
                confidence: 0.95,
                sensitivity: .public,
                userApproved: true
            ),
            MemoryItem(
                id: "project_1",
                category: .project,
                content: "Repository: Pearl, active branch: feat/v3-memory",
                source: "system",
                provenance: "git",
                confidence: 1.0,
                sensitivity: .personal,
                userApproved: true
            ),
            MemoryItem(
                id: "episodic_1",
                category: .episodic,
                content: "Calibrated voice pipeline and verified 60 Hz metering with user",
                source: "observation",
                provenance: "session_turn_42",
                confidence: 0.9,
                sensitivity: .personal,
                userApproved: true
            ),
            MemoryItem(
                id: "working_1",
                category: .working,
                content: "Current conversational scratchpad: inspecting memory.sqlite tables",
                source: "user",
                provenance: "scratchpad",
                confidence: 1.0,
                sensitivity: .personal,
                userApproved: true
            ),
            MemoryItem(
                id: "task_1",
                category: .task,
                content: "Submit Phase M2 memory architecture pull request before 5 PM",
                source: "user",
                provenance: "user",
                confidence: 1.0,
                sensitivity: .personal,
                userApproved: true,
                validUntil: "2026-11-14T17:00:00Z"
            )
        ]
        
        for item in items {
            let (saved, _) = try await store.saveItem(item)
            XCTAssertEqual(saved.id, item.id)
        }
        
        // Verify total user items count (excluding default profile_main document)
        let nonMain = (await store.getAllItems()).filter { $0.id != "profile_main" }
        XCTAssertEqual(nonMain.count, 6)
        
        // Verify category-specific queries
        for category in MemoryCategory.allCases {
            let catItems = (await store.getAllItems(category: category)).filter { $0.id != "profile_main" }
            XCTAssertEqual(catItems.count, 1, "Expected exactly 1 item in category \(category.rawValue)")
            XCTAssertEqual(catItems.first?.category, category)
        }
    }
    
    // MARK: - Test 2: Structured SQLite Schema (12 Fields)
    
    func testCanonicalSQLiteTableSchema() async throws {
        let item = MemoryItem(
            id: "structured_schema_test",
            category: .project,
            content: "Technical decision: Use WAL mode for concurrent SQLite reads",
            source: "user",
            provenance: "architecture_review",
            confidence: 0.98,
            sensitivity: .sensitive,
            userApproved: true,
            createdAt: "2026-11-14T10:00:00.000Z",
            updatedAt: "2026-11-14T10:30:00.000Z",
            validUntil: "2027-01-01T00:00:00.000Z",
            relatedEntityId: "decision.wal_mode"
        )
        
        _ = try await store.saveItem(item)
        
        let retrieved = await store.getItem(id: "structured_schema_test")
        XCTAssertNotNil(retrieved)
        
        guard let r = retrieved else { return }
        XCTAssertEqual(r.id, "structured_schema_test")
        XCTAssertEqual(r.category, .project)
        XCTAssertEqual(r.content, "Technical decision: Use WAL mode for concurrent SQLite reads")
        XCTAssertEqual(r.source, "user")
        XCTAssertEqual(r.provenance, "architecture_review")
        XCTAssertEqual(r.confidence, 0.98, accuracy: 1e-4)
        XCTAssertEqual(r.sensitivity, .sensitive)
        XCTAssertTrue(r.userApproved)
        XCTAssertEqual(r.createdAt, "2026-11-14T10:00:00.000Z")
        XCTAssertEqual(r.updatedAt, "2026-11-14T10:30:00.000Z")
        XCTAssertEqual(r.validUntil, "2027-01-01T00:00:00.000Z")
        XCTAssertEqual(r.relatedEntityId, "decision.wal_mode")
    }
    
    // MARK: - Test 3: Deduplication
    
    func testMemoryDeduplication() async throws {
        let fact1 = MemoryItem(
            id: "dedup_1",
            category: .semantic,
            content: "Lives in San Francisco near Mission Bay",
            source: "user"
        )
        _ = try await store.saveItem(fact1)
        
        let initialCount = await store.getAllItems(category: .semantic).count
        XCTAssertEqual(initialCount, 1)
        
        // Exact duplicate
        let factDuplicate = MemoryItem(
            id: "dedup_2",
            category: .semantic,
            content: "Lives in San Francisco near Mission Bay",
            source: "user"
        )
        let (savedDup, wasCorrected) = try await store.saveItem(factDuplicate)
        XCTAssertFalse(wasCorrected)
        XCTAssertEqual(savedDup.id, "dedup_1", "Duplicate should reuse existing fact ID")
        
        // Normalized duplicate with differing whitespace and case
        let factNormalizedDup = MemoryItem(
            id: "dedup_3",
            category: .semantic,
            content: "  lives in san francisco near mission bay!  ",
            source: "user"
        )
        let (savedNorm, wasNormCorrected) = try await store.saveItem(factNormalizedDup)
        XCTAssertFalse(wasNormCorrected)
        XCTAssertEqual(savedNorm.id, "dedup_1")
        
        let finalCount = await store.getAllItems(category: .semantic).count
        XCTAssertEqual(finalCount, 1, "Duplicate insertions must not increment record count")
    }
    
    // MARK: - Test 4: Entity Fact Correction
    
    func testEntityFactCorrection() async throws {
        // Initial statement: "User favorite language is Swift"
        let initialFact = MemoryItem(
            id: "lang_pref",
            category: .semantic,
            content: "User favorite language is Swift",
            source: "user"
        )
        _ = try await store.saveItem(initialFact)
        
        let countBefore = await store.getAllItems(category: .semantic).count
        XCTAssertEqual(countBefore, 1)
        
        // New stated value for same entity: "User favorite language is Rust"
        let updatedFact = MemoryItem(
            id: "lang_pref_new",
            category: .semantic,
            content: "User favorite language is Rust",
            source: "user"
        )
        let (saved, wasCorrected) = try await store.saveItem(updatedFact)
        
        XCTAssertTrue(wasCorrected, "Should detect new value for existing entity as fact correction")
        XCTAssertEqual(saved.id, "lang_pref", "Correction should update existing fact ID")
        XCTAssertEqual(saved.content, "User favorite language is Rust")
        
        let countAfter = await store.getAllItems(category: .semantic).count
        XCTAssertEqual(countAfter, 1, "Fact correction must replace in-place, not create duplicate row")
        
        // Verify FTS search finds the updated content and not the old content
        let rustSearch = await store.search(query: "Rust")
        XCTAssertFalse(rustSearch.isEmpty)
        XCTAssertEqual(rustSearch.first?.content, "User favorite language is Rust")
    }
    
    // MARK: - Test 5: Bidirectional Sync to Inspectable Markdown
    
    func testBidirectionalSyncWithMarkdown() async throws {
        // 1. Export from SQLite to Markdown
        let item1 = MemoryItem(
            id: "sync_task_1",
            category: .task,
            content: "Prepare release notes for v3.0",
            source: "user"
        )
        let item2 = MemoryItem(
            id: "sync_project_1",
            category: .project,
            content: "Pearl V3 codebase located in ~/Projects/Pearl",
            source: "user"
        )
        _ = try await store.saveItem(item1)
        _ = try await store.saveItem(item2)
        
        // Check facts.md exists and contains the items
        let factsContent = try String(contentsOf: store.factsURL, encoding: .utf8)
        XCTAssertTrue(factsContent.contains("Prepare release notes for v3.0"))
        XCTAssertTrue(factsContent.contains("Pearl V3 codebase located in ~/Projects/Pearl"))
        XCTAssertTrue(factsContent.contains("[category: task]"))
        XCTAssertTrue(factsContent.contains("[category: project]"))
        
        // 2. Human edits facts.md directly by appending a new bullet
        let newBullet = "- [id: human_edit_fact] (user, 2026-11-14) [category: semantic]: Human added fact via text editor\n"
        let updatedContent = factsContent + newBullet
        try updatedContent.write(to: store.factsURL, atomically: true, encoding: .utf8)
        
        // 3. Sync from markdown into SQLite
        try await store.syncFromMarkdown()
        
        let syncedItem = await store.getItem(id: "human_edit_fact")
        XCTAssertNotNil(syncedItem)
        XCTAssertEqual(syncedItem?.content, "Human added fact via text editor")
        XCTAssertEqual(syncedItem?.category, .semantic)
    }
    
    // MARK: - Test 6: Ranked BM25 Retrieval Across Categories
    
    func testFTS5RankedBM25RetrievalAcrossCategories() async throws {
        let items: [MemoryItem] = [
            MemoryItem(category: .profile, content: "Prefers Swift programming language for high performance systems"),
            MemoryItem(category: .semantic, content: "Swift concurrency provides actors and structured concurrency"),
            MemoryItem(category: .project, content: "Pearl Core is implemented natively in Swift 6"),
            MemoryItem(category: .task, content: "Review Swift package dependencies for security vulnerabilities"),
            MemoryItem(category: .episodic, content: "Reflected on migrating from Python daemon to pure native Swift")
        ]
        
        for item in items {
            _ = try await store.saveItem(item)
        }
        
        // Search across all categories
        let allResults = await store.search(query: "Swift concurrency", topK: 5)
        XCTAssertFalse(allResults.isEmpty)
        XCTAssertTrue(allResults.count <= 5)
        
        // Top ranked match should be semantic item mentioning "Swift concurrency"
        let topResult = allResults.first!
        XCTAssertTrue(topResult.content.contains("Swift concurrency"))
        
        // Search filtered by specific category
        let projectResults = await store.search(query: "Swift", category: .project, topK: 5)
        XCTAssertEqual(projectResults.count, 1)
        XCTAssertEqual(projectResults.first?.category, .project)
        XCTAssertTrue(projectResults.first!.content.contains("Pearl Core"))
    }
    
    // MARK: - Test 7: Migration Without Data Loss (Requirement 6)
    
    func testMigrationWithoutDataLoss() async throws {
        // Set up legacy memory directory mimicking V2 (~/Library/Application Support/Pearl/memory/facts.md)
        let legacyMemDir = tempDirectory.appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: legacyMemDir, withIntermediateDirectories: true)
        let legacyFactsURL = legacyMemDir.appendingPathComponent("facts.md")
        
        let legacyFactsContent = """
        # Pearl Facts
        <!-- Stored facts with provenance. One bullet per fact: - [id: ID] (source, YYYY-MM-DD): content -->

        - [id: leg_1] (user, 2026-11-13): MacBook battery charge threshold set to 80 percent
        - [id: leg_2] (user, 2026-11-13) [category: project]: Working on Axiom frontend with liquid glass aesthetics
        - [id: leg_3] (user, 2026-11-13) [category: task]: Team standup tomorrow morning at 9 AM
        """
        try legacyFactsContent.write(to: legacyFactsURL, atomically: true, encoding: .utf8)
        
        // Execute migration
        try await store.performMigration()
        
        // Verify facts are imported into SQLite canonical store
        let fact1 = await store.getItem(id: "leg_1")
        XCTAssertNotNil(fact1)
        XCTAssertEqual(fact1?.content, "MacBook battery charge threshold set to 80 percent")
        XCTAssertEqual(fact1?.category, .semantic)
        
        let fact2 = await store.getItem(id: "leg_2")
        XCTAssertNotNil(fact2)
        XCTAssertEqual(fact2?.category, .project)
        XCTAssertTrue(fact2!.content.contains("Axiom frontend"))
        
        let fact3 = await store.getItem(id: "leg_3")
        XCTAssertNotNil(fact3)
        XCTAssertEqual(fact3?.category, .task)
        XCTAssertTrue(fact3!.content.contains("standup"))
        
        // Verify facts.md was exported with migrated facts
        let factsMd = try String(contentsOf: store.factsURL, encoding: .utf8)
        XCTAssertTrue(factsMd.contains("leg_1"))
        XCTAssertTrue(factsMd.contains("leg_2"))
        XCTAssertTrue(factsMd.contains("leg_3"))
    }
}
