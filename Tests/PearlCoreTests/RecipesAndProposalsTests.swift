import XCTest
@testable import PearlCore

final class RecipesAndProposalsTests: XCTestCase {
    var tempDirectory: URL!
    
    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() async throws {
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }
    
    // MARK: - SkillEngine Indexing & Search Tests
    
    func testSkillEngineInvertedIndexMatchingAndScoring() async throws {
        let skillsDir = tempDirectory.appendingPathComponent("skills", isDirectory: true)
        let engine = SkillEngine(skillsDirectory: skillsDir)
        try await engine.seedDefaultSkillsIfEmpty()
        
        // Exact trigger match: 1.0
        let exact = await engine.findSkillByTrigger("start my workday")
        XCTAssertNotNil(exact)
        XCTAssertEqual(exact?.skill.name, "start-workday")
        XCTAssertEqual(exact?.score, 1.0)
        
        // Exact command variant: 1.0
        let runSkill = await engine.findSkillByTrigger("run skill start-workday")
        XCTAssertNotNil(runSkill)
        XCTAssertEqual(runSkill?.skill.name, "start-workday")
        XCTAssertEqual(runSkill?.score, 1.0)
        
        let runSkillSpaces = await engine.findSkillByTrigger("run skill start workday")
        XCTAssertNotNil(runSkillSpaces)
        XCTAssertEqual(runSkillSpaces?.skill.name, "start-workday")
        XCTAssertEqual(runSkillSpaces?.score, 1.0)
        
        let skillPrefix = await engine.findSkillByTrigger("skill meeting-prep")
        XCTAssertNotNil(skillPrefix)
        XCTAssertEqual(skillPrefix?.skill.name, "meeting-prep")
        XCTAssertEqual(skillPrefix?.score, 1.0)
        
        // Inverted keyword token overlap match: >= 0.6
        let partialOverlap = await engine.findSkillByTrigger("start workday")
        XCTAssertNotNil(partialOverlap)
        XCTAssertEqual(partialOverlap?.skill.name, "start-workday")
        XCTAssertGreaterThanOrEqual(partialOverlap?.score ?? 0, 0.6)
        
        let prepMeeting = await engine.findSkillByTrigger("prep meeting")
        XCTAssertNotNil(prepMeeting)
        XCTAssertEqual(prepMeeting?.skill.name, "meeting-prep")
        XCTAssertGreaterThanOrEqual(prepMeeting?.score ?? 0, 0.6)
        
        // Irrelevant utterance: nil
        let unrelated = await engine.findSkillByTrigger("completely unrelated sentence about cooking pasta")
        XCTAssertNil(unrelated)
        
        // matchSkill compatibility
        let matched = await engine.matchSkill(for: "start my workday")
        XCTAssertEqual(matched?.name, "start-workday")
    }
    
    func testSkillEngineSearchSkills() async throws {
        let skillsDir = tempDirectory.appendingPathComponent("skills", isDirectory: true)
        let engine = SkillEngine(skillsDirectory: skillsDir)
        try await engine.seedDefaultSkillsIfEmpty()
        
        // Search by keyword in description/steps
        let batteryResults = await engine.searchSkills(query: "battery")
        XCTAssertFalse(batteryResults.isEmpty)
        XCTAssertEqual(batteryResults.first?.name, "start-workday")
        
        let calendarResults = await engine.searchSkills(query: "calendar")
        XCTAssertEqual(calendarResults.count, 2)
        
        // Unmatched keyword
        let emptyResults = await engine.searchSkills(query: "astronomy")
        XCTAssertTrue(emptyResults.isEmpty)
    }
    
    func testSkillEngineIndexInvalidationOnSaveAndDelete() async throws {
        let skillsDir = tempDirectory.appendingPathComponent("skills", isDirectory: true)
        let engine = SkillEngine(skillsDirectory: skillsDir)
        try await engine.seedDefaultSkillsIfEmpty()
        
        let initialSearch = await engine.searchSkills(query: "docker")
        XCTAssertTrue(initialSearch.isEmpty)
        
        let newSkill = SkillDefinition(
            name: "docker-cleanup",
            trigger: "cleanup docker containers",
            description: "Remove dangling images and stopped containers",
            steps: [
                SkillStepDefinition(index: 1, description: "Prune system", utterance: "docker system prune -f")
            ]
        )
        try await engine.saveSkill(newSkill)
        
        // Index is refreshed on save
        let postSaveSearch = await engine.searchSkills(query: "docker")
        XCTAssertEqual(postSaveSearch.count, 1)
        XCTAssertEqual(postSaveSearch.first?.name, "docker-cleanup")
        
        let postSaveTrigger = await engine.findSkillByTrigger("cleanup docker containers")
        XCTAssertNotNil(postSaveTrigger)
        XCTAssertEqual(postSaveTrigger?.skill.name, "docker-cleanup")
        
        // Invalidate and delete
        try await engine.deleteSkill(name: "docker-cleanup")
        let postDeleteSearch = await engine.searchSkills(query: "docker")
        XCTAssertTrue(postDeleteSearch.isEmpty)
        
        let postDeleteTrigger = await engine.findSkillByTrigger("cleanup docker containers")
        XCTAssertNil(postDeleteTrigger)
    }
    
    func testSkillEngineSearchCatalog() {
        let engine = SkillEngine.shared
        let catalog = SkillEngine.builtInCatalog
        
        // 16 blueprints across 8 categories (2 per category)
        XCTAssertEqual(catalog.count, 16)
        
        let categories = Set(catalog.map { $0.category })
        XCTAssertEqual(categories.count, 8)
        let expectedCategories: Set<String> = [
            "Productivity", "Research", "Writing", "Coding",
            "System", "Memory", "Communication", "Analysis"
        ]
        XCTAssertEqual(categories, expectedCategories)
        
        for category in expectedCategories {
            let inCat = catalog.filter { $0.category == category }
            XCTAssertEqual(inCat.count, 2, "Category '\(category)' must have exactly 2 blueprints")
        }
        
        // Filter by category
        let codingBlueprints = engine.searchCatalog(query: "", category: "Coding")
        XCTAssertEqual(codingBlueprints.count, 2)
        XCTAssertTrue(codingBlueprints.allSatisfy { $0.category == "Coding" })
        
        // Search by query
        let reviewBlueprints = engine.searchCatalog(query: "review", category: nil)
        XCTAssertFalse(reviewBlueprints.isEmpty)
        XCTAssertTrue(reviewBlueprints.contains(where: { $0.name == "pr-review" }))
    }
    
    // MARK: - RecipeEngine Tests
    
    func testRecipeEngineDefaultSeeding() throws {
        let recipesDir = tempDirectory.appendingPathComponent("recipes", isDirectory: true)
        let engine = RecipeEngine(recipesDirectory: recipesDir)
        
        let initial = engine.loadRecipes()
        XCTAssertTrue(initial.isEmpty)
        
        try engine.seedDefaultRecipesIfEmpty()
        let seeded = engine.loadRecipes()
        XCTAssertEqual(seeded.count, 3)
        
        let names = Set(seeded.map { $0.name })
        XCTAssertTrue(names.contains("research-topic"))
        XCTAssertTrue(names.contains("competitive-brief"))
        XCTAssertTrue(names.contains("daily-vault-digest"))
        
        // Idempotent
        try engine.seedDefaultRecipesIfEmpty()
        let secondLoad = engine.loadRecipes()
        XCTAssertEqual(secondLoad.count, 3)
    }
    
    func testRecipeEngineFrontmatterParsingAndMatching() throws {
        let recipesDir = tempDirectory.appendingPathComponent("recipes", isDirectory: true)
        let engine = RecipeEngine(recipesDirectory: recipesDir)
        try engine.seedDefaultRecipesIfEmpty()
        
        let recipe = engine.readRecipe(name: "research-topic")
        XCTAssertNotNil(recipe)
        XCTAssertEqual(recipe?.name, "research-topic")
        XCTAssertEqual(recipe?.inputs, ["topic"])
        XCTAssertTrue(recipe?.triggers.contains("research topic") ?? false)
        XCTAssertTrue(recipe?.triggers.contains("deep dive into topic") ?? false)
        XCTAssertTrue(recipe?.body.contains("{{topic}}") ?? false)
        
        // Match by trigger
        let matchedByTrigger = engine.matchRecipe(for: "deep dive into topic")
        XCTAssertEqual(matchedByTrigger?.name, "research-topic")
        
        // Match by "recipe <name>"
        let matchedByCommand = engine.matchRecipe(for: "recipe research-topic")
        XCTAssertEqual(matchedByCommand?.name, "research-topic")
        
        let matchedBySpaces = engine.matchRecipe(for: "recipe research topic")
        XCTAssertEqual(matchedBySpaces?.name, "research-topic")
        
        let unMatched = engine.matchRecipe(for: "make me a pizza")
        XCTAssertNil(unMatched)
    }
    
    func testRecipeEngineRenderInterpolationAndMissingInput() throws {
        let recipesDir = tempDirectory.appendingPathComponent("recipes", isDirectory: true)
        let engine = RecipeEngine(recipesDirectory: recipesDir)
        try engine.seedDefaultRecipesIfEmpty()
        
        // Successful rendering
        let rendered = try engine.renderRecipe(name: "research-topic", arguments: ["topic": "Generative Agents"])
        XCTAssertTrue(rendered.contains("Generative Agents"))
        XCTAssertFalse(rendered.contains("{{topic}}"))
        
        // Missing input error
        XCTAssertThrowsError(try engine.renderRecipe(name: "research-topic", arguments: [:])) { error in
            guard let recipeError = error as? RecipeEngineError else {
                XCTFail("Expected RecipeEngineError")
                return
            }
            XCTAssertEqual(recipeError, .missingRequiredInput("topic"))
        }
        
        // Unknown recipe error
        XCTAssertThrowsError(try engine.renderRecipe(name: "nonexistent", arguments: [:])) { error in
            guard let recipeError = error as? RecipeEngineError else {
                XCTFail("Expected RecipeEngineError")
                return
            }
            XCTAssertEqual(recipeError, .recipeNotFound("nonexistent"))
        }
    }
    
    func testRecipeEngineSaveAndDelete() throws {
        let recipesDir = tempDirectory.appendingPathComponent("recipes", isDirectory: true)
        let engine = RecipeEngine(recipesDirectory: recipesDir)
        
        let customRecipe = RecipeDefinition(
            name: "incident-postmortem",
            description: "Generate postmortem analysis for an incident",
            triggers: ["create postmortem", "incident postmortem"],
            inputs: ["incident_id", "severity"],
            body: "1. Load logs for incident {{incident_id}}\n2. Review severity {{severity}} impact"
        )
        
        let savedURL = try engine.saveRecipe(customRecipe)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        
        let loaded = engine.readRecipe(name: "incident-postmortem")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.inputs, ["incident_id", "severity"])
        
        try engine.deleteRecipe(name: "incident-postmortem")
        XCTAssertNil(engine.readRecipe(name: "incident-postmortem"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path))
    }
    
    // MARK: - ProposalStore Tests
    
    func testProposalStoreUnifiedDiffGeneration() {
        // Create diff
        let createProposal = SkillProposal(
            title: "New skill",
            targetName: "daily-sync",
            targetKind: .skill,
            changeType: .create,
            oldContent: "",
            newContent: "1. check battery\n2. list calendar events",
            explanation: "Daily sync macro"
        )
        let createDiff = createProposal.unifiedDiff()
        XCTAssertTrue(createDiff.contains("--- a/skill/daily-sync.md"))
        XCTAssertTrue(createDiff.contains("+++ b/skill/daily-sync.md"))
        XCTAssertTrue(createDiff.contains("@@ -0,0 +1,2 @@"))
        XCTAssertTrue(createDiff.contains("+1. check battery"))
        XCTAssertTrue(createDiff.contains("+2. list calendar events"))
        
        // Edit diff
        let editProposal = SkillProposal(
            title: "Edit skill",
            targetName: "daily-sync",
            targetKind: .skill,
            changeType: .edit,
            oldContent: "line 1\nline 2",
            newContent: "line 1\nline modified",
            explanation: "Update line"
        )
        let editDiff = editProposal.unifiedDiff()
        XCTAssertTrue(editDiff.contains("--- a/skill/daily-sync.md"))
        XCTAssertTrue(editDiff.contains("+++ b/skill/daily-sync.md"))
        XCTAssertTrue(editDiff.contains(" line 1"))
        XCTAssertTrue(editDiff.contains("-line 2"))
        XCTAssertTrue(editDiff.contains("+line modified"))
        
        // Delete diff
        let deleteProposal = SkillProposal(
            title: "Delete recipe",
            targetName: "old-recipe",
            targetKind: .recipe,
            changeType: .delete,
            oldContent: "deprecated content",
            newContent: "",
            explanation: "Clean up"
        )
        let deleteDiff = deleteProposal.unifiedDiff()
        XCTAssertTrue(deleteDiff.contains("--- a/recipe/old-recipe.md"))
        XCTAssertTrue(deleteDiff.contains("+++ b/recipe/old-recipe.md"))
        XCTAssertTrue(deleteDiff.contains("-deprecated content"))
    }
    
    func testProposalStoreLifecycleAndAtomicPersistence() throws {
        let queueURL = tempDirectory.appendingPathComponent("proposals").appendingPathComponent("queue.json")
        let store = ProposalStore(queueFileURL: queueURL)
        
        let proposal = try store.createProposal(
            title: "Add quick note skill",
            targetName: "quick-note",
            targetKind: .skill,
            changeType: .create,
            oldContent: "",
            newContent: "1. append to note",
            explanation: "Captures quick notes"
        )
        
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertEqual(store.listPending().count, 1)
        XCTAssertEqual(store.listAll().count, 1)
        
        // Edit proposal
        let updated = try store.editProposal(id: proposal.id, newContent: "1. append to daily note")
        XCTAssertEqual(updated.newContent, "1. append to daily note")
        
        // Verify atomic persistence by loading a fresh store instance from same queueURL
        let reloadedStore = ProposalStore(queueFileURL: queueURL)
        let persisted = reloadedStore.getProposal(id: proposal.id)
        XCTAssertNotNil(persisted)
        XCTAssertEqual(persisted?.newContent, "1. append to daily note")
        XCTAssertEqual(persisted?.status, .pending)
        
        // Reject proposal
        let rejected = try reloadedStore.rejectProposal(id: proposal.id)
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertEqual(reloadedStore.listPending().count, 0)
        XCTAssertEqual(reloadedStore.listAll().count, 1)
    }
    
    func testProposalStoreApproveProposalWritesMarkdown() throws {
        let queueURL = tempDirectory.appendingPathComponent("proposals").appendingPathComponent("queue.json")
        let store = ProposalStore(queueFileURL: queueURL)
        let skillsDir = tempDirectory.appendingPathComponent("skills", isDirectory: true)
        let recipesDir = tempDirectory.appendingPathComponent("recipes", isDirectory: true)
        
        // Approve skill creation
        let skillProp = try store.createProposal(
            title: "Create test skill",
            targetName: "test-macro",
            targetKind: .skill,
            changeType: .create,
            oldContent: "",
            newContent: "1. step one\n2. step two",
            explanation: "Test proposal"
        )
        
        let approvedSkill = try store.approveProposal(id: skillProp.id, skillsDir: skillsDir, recipesDir: recipesDir)
        XCTAssertEqual(approvedSkill.status, .approved)
        
        let writtenSkillFile = skillsDir.appendingPathComponent("test-macro.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: writtenSkillFile.path))
        let writtenSkillContent = try String(contentsOf: writtenSkillFile, encoding: .utf8)
        XCTAssertEqual(writtenSkillContent, "1. step one\n2. step two")
        
        // Approve recipe creation
        let recipeProp = try store.createProposal(
            title: "Create test recipe",
            targetName: "test-recipe",
            targetKind: .recipe,
            changeType: .create,
            oldContent: "",
            newContent: "---\nname: test-recipe\n---\n1. do something",
            explanation: "Recipe proposal"
        )
        
        let approvedRecipe = try store.approveProposal(id: recipeProp.id, skillsDir: skillsDir, recipesDir: recipesDir)
        XCTAssertEqual(approvedRecipe.status, .approved)
        
        let writtenRecipeFile = recipesDir.appendingPathComponent("test-recipe.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: writtenRecipeFile.path))
        
        // Approve deletion
        let deleteProp = try store.createProposal(
            title: "Delete test skill",
            targetName: "test-macro",
            targetKind: .skill,
            changeType: .delete,
            oldContent: "1. step one\n2. step two",
            newContent: "",
            explanation: "Delete test macro"
        )
        try store.approveProposal(id: deleteProp.id, skillsDir: skillsDir, recipesDir: recipesDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writtenSkillFile.path))
    }
    
    func testCompileRecipeToSkillProposal() throws {
        let recipesDir = tempDirectory.appendingPathComponent("recipes", isDirectory: true)
        let recipeEngine = RecipeEngine(recipesDirectory: recipesDir)
        try recipeEngine.seedDefaultRecipesIfEmpty()
        
        let queueURL = tempDirectory.appendingPathComponent("proposals").appendingPathComponent("queue.json")
        let store = ProposalStore(queueFileURL: queueURL)
        
        let proposal = try recipeEngine.compileToSkillProposal(
            name: "research-topic",
            defaultArguments: ["topic": "Autonomous AI Agents"],
            proposalStore: store
        )
        
        XCTAssertEqual(proposal.targetName, "research-topic")
        XCTAssertEqual(proposal.targetKind, .skill)
        XCTAssertEqual(proposal.changeType, .create)
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertTrue(proposal.newContent.contains("Autonomous AI Agents"))
        XCTAssertTrue(proposal.newContent.contains("name: research-topic"))
        XCTAssertTrue(proposal.newContent.contains("1. Search the web for Autonomous AI Agents recent developments"))
        
        let diff = proposal.unifiedDiff()
        XCTAssertTrue(diff.contains("+++ b/skill/research-topic.md"))
        XCTAssertTrue(diff.contains("+1. Search the web for Autonomous AI Agents recent developments"))
    }
}
