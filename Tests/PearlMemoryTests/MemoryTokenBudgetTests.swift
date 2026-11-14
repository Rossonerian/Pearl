import XCTest
@testable import PearlCore
@testable import PearlMemory

final class MemoryTokenBudgetTests: XCTestCase {
    var tempDirectory: URL!
    var store: MemoryStore!
    
    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = try MemoryStore(baseDirectory: tempDirectory)
    }
    
    override func tearDown() async throws {
        store = nil
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }
    
    // MARK: - Token Estimation Heuristics
    
    func testEstimateTokenCountEmptyString() {
        XCTAssertEqual(estimateTokenCount(""), 0)
        XCTAssertEqual(estimateTokenCount("   \n\t  "), 0)
    }
    
    func testEstimateTokenCountShortText() {
        let count = estimateTokenCount("Hello world")
        XCTAssertGreaterThanOrEqual(count, 2)
        XCTAssertLessThanOrEqual(count, 5)
    }
    
    func testEstimateTokenCountLongText() {
        let words = Array(repeating: "apple", count: 100).joined(separator: " ")
        let count = estimateTokenCount(words)
        // 100 words * 1.3 ~= 130 tokens
        XCTAssertGreaterThanOrEqual(count, 100)
        XCTAssertLessThanOrEqual(count, 160)
    }
    
    func testEstimateTokenCountPunctuationAndMarkdown() {
        let md = "### Section Header\n- Bullet 1: [Link](https://example.com)\n- Bullet 2: `code block`"
        let count = estimateTokenCount(md)
        XCTAssertGreaterThan(count, 10)
    }
    
    // MARK: - Context Budget Checks
    
    func testContextBudgetInvariants() {
        XCTAssertEqual(ContextBudget.maxProfileTokens, 600)
        XCTAssertEqual(ContextBudget.maxProfileSizeBytes, 1536)
        XCTAssertEqual(ContextBudget.maxRetrievedSnippets, 5)
        
        let validBudget = ContextBudget(profileTokens: 500, retrievedSnippetCount: 4, totalTokens: 800)
        XCTAssertTrue(validBudget.isWithinBudget)
        
        let profileOverBudget = ContextBudget(profileTokens: 601, retrievedSnippetCount: 2, totalTokens: 900)
        XCTAssertFalse(profileOverBudget.isWithinBudget)
        
        let snippetsOverBudget = ContextBudget(profileTokens: 400, retrievedSnippetCount: 6, totalTokens: 900)
        XCTAssertFalse(snippetsOverBudget.isWithinBudget)
    }
    
    // MARK: - Context Assembler Budget Enforcement
    
    func testContextAssemblerWithinBudget() async throws {
        try await store.setProfile("# User Profile\n- Name: Alice\n- Editor: VSCode")
        
        let context = try await ContextAssembler.assemble(query: "editor", store: store, topK: 3)
        XCTAssertTrue(context.isWithinBudget)
        XCTAssertLessThanOrEqual(context.profileTokens, ContextBudget.maxProfileTokens)
        XCTAssertTrue(context.promptSection.contains("Alice"))
        XCTAssertTrue(context.promptSection.contains("System Persona"))
    }
    
    func testPersonaReadOnlyThrows() async {
        do {
            try await store.updatePersona("Hacked persona")
            XCTFail("Expected personaReadOnly error")
        } catch MemoryError.personaReadOnly {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testContextAssemblerThrowsWhenProfileExceedsBudget() async throws {
        // Generate profile that exceeds 600 tokens
        let hugeProfile = Array(repeating: "preferences and settings for the user environment", count: 100).joined(separator: "\n")
        
        // Write directly to file to bypass MemoryStore updateProfile validation
        try hugeProfile.write(to: store.profileURL, atomically: true, encoding: .utf8)
        
        do {
            _ = try await ContextAssembler.assemble(query: "settings", store: store)
            XCTFail("Expected profileExceedsBudget error")
        } catch let MemoryError.profileExceedsBudget(bytes, tokens) {
            XCTAssertGreaterThan(tokens, ContextBudget.maxProfileTokens)
            XCTAssertGreaterThan(bytes, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    // MARK: - MemoryFact Bullet Serialization & Parsing
    
    func testMemoryFactMarkdownSerializationAndParsing() {
        let fact = MemoryFact(id: "uuid-1234", source: "user", date: "2026-11-14", content: "Prefers dark mode")
        let bullet = fact.toMarkdownBullet()
        XCTAssertEqual(bullet, "- [id: uuid-1234] (user, 2026-11-14): Prefers dark mode")
        
        guard let parsed = MemoryFact.parseBullet(bullet) else {
            return XCTFail("Failed to parse bullet: \(bullet)")
        }
        XCTAssertEqual(parsed.id, "uuid-1234")
        XCTAssertEqual(parsed.source, "user")
        XCTAssertEqual(parsed.date, "2026-11-14")
        XCTAssertEqual(parsed.content, "Prefers dark mode")
    }
    
    func testMemoryFactParseMalformedBulletReturnsNil() {
        XCTAssertNil(MemoryFact.parseBullet("# Header line"))
        XCTAssertNil(MemoryFact.parseBullet("- Regular bullet without ID"))
        XCTAssertNil(MemoryFact.parseBullet("- [id: ] (user, 2026-11-14): Empty ID"))
        XCTAssertNil(MemoryFact.parseBullet("- [id: 123] missing parentheses: content"))
        XCTAssertNil(MemoryFact.parseBullet(""))
    }
}
