import Foundation

/// Represents a parameterized recipe template loaded from Markdown.
public struct RecipeDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let triggers: [String]
    public let inputs: [String]
    public let body: String
    public let fileURL: URL?
    
    public init(
        name: String,
        description: String,
        triggers: [String],
        inputs: [String],
        body: String,
        fileURL: URL? = nil
    ) {
        self.name = name
        self.description = description
        self.triggers = triggers
        self.inputs = inputs
        self.body = body
        self.fileURL = fileURL
    }
}

public enum RecipeEngineError: Error, LocalizedError, Equatable {
    case recipeNotFound(String)
    case missingRequiredInput(String)
    
    public var errorDescription: String? {
        switch self {
        case .recipeNotFound(let name): return "Recipe not found: '\(name)'"
        case .missingRequiredInput(let input): return "Missing required recipe input: '\(input)'"
        }
    }
}

/// Engine managing declarative parameterized recipes and compiling them into skills.
public final class RecipeEngine: @unchecked Sendable {
    public static let shared = RecipeEngine()
    
    public static var defaultRecipesDirectory: URL {
        return PearlStoragePaths.subdirectory(named: "recipes")
    }
    
    public let recipesDirectory: URL
    private let lock = NSLock()
    private var didEnsureSeeded = false
    
    public init(recipesDirectory: URL? = nil) {
        self.recipesDirectory = recipesDirectory ?? Self.defaultRecipesDirectory
    }
    
    public func ensureSeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didEnsureSeeded else { return }
        didEnsureSeeded = true
        try? seedDefaultRecipesIfEmpty()
    }
    
    /// Seeds default parameterized recipes if the recipes directory has zero `.md` files.
    public func seedDefaultRecipesIfEmpty() throws {
        try FileManager.default.createDirectory(at: recipesDirectory, withIntermediateDirectories: true)
        
        let existing = (try? FileManager.default.contentsOfDirectory(at: recipesDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "md" } ?? []
        guard existing.isEmpty else { return }
        
        // 1. research-topic.md
        let researchTopic = """
        ---
        name: research-topic
        description: Deep research on a specified topic using web searches and synthesis
        triggers:
          - research topic
          - deep dive into topic
        inputs:
          - topic
        ---
        1. Search the web for {{topic}} recent developments
        2. Summarize key articles and findings on {{topic}}
        3. Save research brief to vault
        """
        try researchTopic.write(
            to: recipesDirectory.appendingPathComponent("research-topic.md"),
            atomically: true,
            encoding: .utf8
        )
        
        // 2. competitive-brief.md
        let competitiveBrief = """
        ---
        name: competitive-brief
        description: Prepare a competitive intelligence brief for a target company
        triggers:
          - analyze competitor
          - competitive brief
        inputs:
          - company
        ---
        1. Search recent announcements and product launches for {{company}}
        2. Analyze competitive strengths and weaknesses of {{company}}
        3. Compile comparison matrix against {{company}}
        """
        try competitiveBrief.write(
            to: recipesDirectory.appendingPathComponent("competitive-brief.md"),
            atomically: true,
            encoding: .utf8
        )
        
        // 3. daily-vault-digest.md
        let dailyVaultDigest = """
        ---
        name: daily-vault-digest
        description: Generate daily digest from Obsidian vault focusing on a given area
        triggers:
          - daily vault digest
          - focus vault digest
        inputs:
          - focus
        ---
        1. Search vault notes tagged with {{focus}}
        2. Extract action items related to {{focus}}
        3. Generate structured daily digest for {{focus}}
        """
        try dailyVaultDigest.write(
            to: recipesDirectory.appendingPathComponent("daily-vault-digest.md"),
            atomically: true,
            encoding: .utf8
        )
    }
    
    /// Loads all recipes from markdown files in the recipes directory.
    public func loadRecipes() -> [RecipeDefinition] {
        lock.lock()
        defer { lock.unlock() }
        
        guard FileManager.default.fileExists(atPath: recipesDirectory.path),
              let files = try? FileManager.default.contentsOfDirectory(at: recipesDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        
        var recipes: [RecipeDefinition] = []
        for file in files where file.pathExtension.lowercased() == "md" {
            if let recipe = parseRecipeFile(at: file) {
                recipes.append(recipe)
            }
        }
        return recipes.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
    
    /// Retrieves a single recipe definition by name.
    public func readRecipe(name: String) -> RecipeDefinition? {
        let recipes = loadRecipes()
        let cleanName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "-")
        return recipes.first {
            $0.name.lowercased() == name.lowercased() ||
            $0.name.lowercased().replacingOccurrences(of: " ", with: "-") == cleanName
        }
    }
    
    /// Saves a recipe definition as markdown to the recipes directory.
    @discardableResult
    public func saveRecipe(_ recipe: RecipeDefinition) throws -> URL {
        try FileManager.default.createDirectory(at: recipesDirectory, withIntermediateDirectories: true)
        
        let cleanName = recipe.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "-")
        let fileURL = recipesDirectory.appendingPathComponent("\(cleanName).md")
        
        var lines: [String] = []
        lines.append("---")
        lines.append("name: \(recipe.name)")
        lines.append("description: \(recipe.description)")
        lines.append("triggers:")
        for trigger in recipe.triggers {
            lines.append("  - \(trigger)")
        }
        lines.append("inputs:")
        for input in recipe.inputs {
            lines.append("  - \(input)")
        }
        lines.append("---")
        lines.append(recipe.body)
        lines.append("")
        
        let content = lines.joined(separator: "\n")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
    
    /// Deletes a recipe by name.
    public func deleteRecipe(name: String) throws {
        let cleanName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "-")
        let fileURL = recipesDirectory.appendingPathComponent("\(cleanName).md")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
            return
        }
        if let match = readRecipe(name: name), let url = match.fileURL, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            return
        }
        throw RecipeEngineError.recipeNotFound(name)
    }
    
    /// Matches normalized utterance against recipe triggers and recipe invocation syntax.
    public func matchRecipe(for utterance: String) -> RecipeDefinition? {
        let normalized = utterance.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        
        let recipes = loadRecipes()
        for recipe in recipes {
            let name = recipe.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let nameNoHyphens = name.replacingOccurrences(of: "-", with: " ")
            
            if normalized == "recipe \(name)" || normalized == "recipe \(nameNoHyphens)" ||
               normalized == "run recipe \(name)" || normalized == "run recipe \(nameNoHyphens)" {
                return recipe
            }
            
            for trigger in recipe.triggers {
                let trig = trigger.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if normalized == trig {
                    return recipe
                }
            }
        }
        return nil
    }
    
    /// Substitutes {{key}} placeholders in the recipe body with argument values.
    public func renderRecipe(name: String, arguments: [String: String]) throws -> String {
        guard let recipe = readRecipe(name: name) else {
            throw RecipeEngineError.recipeNotFound(name)
        }
        
        // Check that all required inputs are present
        for input in recipe.inputs {
            let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let val = arguments[trimmedInput], !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RecipeEngineError.missingRequiredInput(trimmedInput)
            }
        }
        
        var rendered = recipe.body
        for (key, val) in arguments {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            rendered = rendered.replacingOccurrences(of: "{{\(trimmedKey)}}", with: val)
            rendered = rendered.replacingOccurrences(of: "{{ \(trimmedKey) }}", with: val)
        }
        return rendered
    }
    
    /// Compiles a recipe into a concrete SkillProposal staged in ProposalStore.
    public func compileToSkillProposal(
        name: String,
        defaultArguments: [String: String] = [:],
        proposalStore: ProposalStore = .shared
    ) throws -> SkillProposal {
        guard let recipe = readRecipe(name: name) else {
            throw RecipeEngineError.recipeNotFound(name)
        }
        
        var args = defaultArguments
        for input in recipe.inputs {
            if args[input] == nil || args[input]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                args[input] = "<\(input)>"
            }
        }
        
        let renderedBody = try renderRecipe(name: name, arguments: args)
        
        let bodyLines = renderedBody.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        var formattedSteps: [String] = []
        var stepCounter = 1
        for line in bodyLines {
            let stepRegex = try? NSRegularExpression(pattern: #"^(\d+)[\.\)]\s*(.*)$"#)
            let nsLine = line as NSString
            if let match = stepRegex?.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                let body = nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                formattedSteps.append("\(stepCounter). \(body)")
            } else {
                formattedSteps.append("\(stepCounter). \(line)")
            }
            stepCounter += 1
        }
        
        let trigger = recipe.triggers.first ?? recipe.name.replacingOccurrences(of: "-", with: " ")
        var skillMDLines: [String] = []
        skillMDLines.append("---")
        skillMDLines.append("name: \(recipe.name)")
        skillMDLines.append("trigger: \(trigger)")
        skillMDLines.append("description: \(recipe.description)")
        skillMDLines.append("---")
        skillMDLines.append(contentsOf: formattedSteps)
        skillMDLines.append("")
        
        let skillContent = skillMDLines.joined(separator: "\n")
        
        return try proposalStore.createProposal(
            title: "Skill from Recipe: \(recipe.name)",
            targetName: recipe.name,
            targetKind: .skill,
            changeType: .create,
            oldContent: "",
            newContent: skillContent,
            explanation: "Compiled from recipe '\(recipe.name)'"
        )
    }
    
    // MARK: - Markdown Parsing
    
    private func parseRecipeFile(at fileURL: URL) -> RecipeDefinition? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        
        let lines = content.components(separatedBy: .newlines)
        var name: String?
        var description: String?
        var triggers: [String] = []
        var inputs: [String] = []
        var bodyLines: [String] = []
        
        var inFrontmatter = false
        var frontmatterEncountered = false
        var currentSection: String? = nil
        
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            
            if trimmed == "---" {
                if !frontmatterEncountered {
                    inFrontmatter = true
                    frontmatterEncountered = true
                    continue
                } else if inFrontmatter {
                    inFrontmatter = false
                    currentSection = nil
                    continue
                }
            }
            
            if inFrontmatter {
                if trimmed.lowercased().hasPrefix("name:") {
                    let val = String(trimmed.dropFirst("name:".count)).trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty { name = val }
                    currentSection = nil
                    continue
                } else if trimmed.lowercased().hasPrefix("description:") {
                    let val = String(trimmed.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty { description = val }
                    currentSection = nil
                    continue
                } else if trimmed.lowercased().hasPrefix("triggers:") {
                    let val = String(trimmed.dropFirst("triggers:".count)).trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty {
                        triggers.append(contentsOf: val.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                    }
                    currentSection = "triggers"
                    continue
                } else if trimmed.lowercased().hasPrefix("inputs:") {
                    let val = String(trimmed.dropFirst("inputs:".count)).trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty {
                        inputs.append(contentsOf: val.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                    }
                    currentSection = "inputs"
                    continue
                }
                
                if currentSection == "triggers" && trimmed.hasPrefix("-") {
                    let item = String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                    if !item.isEmpty { triggers.append(item) }
                    continue
                }
                if currentSection == "inputs" && trimmed.hasPrefix("-") {
                    let item = String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                    if !item.isEmpty { inputs.append(item) }
                    continue
                }
            } else if frontmatterEncountered {
                bodyLines.append(rawLine)
            }
        }
        
        let finalName = name ?? fileURL.deletingPathExtension().lastPathComponent
        let finalDescription = description ?? finalName
        let finalBody = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        
        return RecipeDefinition(
            name: finalName,
            description: finalDescription,
            triggers: triggers,
            inputs: inputs,
            body: finalBody,
            fileURL: fileURL
        )
    }
}
