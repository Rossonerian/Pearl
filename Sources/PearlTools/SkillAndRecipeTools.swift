import Foundation
import PearlCore

// MARK: - ProposeSkillTool

/// Stages a proposed skill or recipe change as a unified-diff review item in `ProposalStore`.
/// Never writes directly to live `skills/` or `recipes/` directories until explicitly approved.
public final class ProposeSkillTool: PearlTool {
    public let name = "propose_skill"
    public let description = "Propose a new or updated Markdown skill or recipe into the review queue for user approval (unified diff, never auto-applied)"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = []
    public let isReversible = true

    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "name", type: "string", description: "Target slug name (e.g. morning-standup)", isRequired: true),
            ToolArgumentDescriptor(name: "target_kind", type: "string", description: "Target artifact kind: skill or recipe (default skill)", isRequired: false, allowedValues: ["skill", "recipe"]),
            ToolArgumentDescriptor(name: "change_type", type: "string", description: "Change kind: create, edit, or delete (auto-detected if omitted)", isRequired: false, allowedValues: ["create", "edit", "delete"]),
            ToolArgumentDescriptor(name: "title", type: "string", description: "Short human-readable title for the proposal", isRequired: false),
            ToolArgumentDescriptor(name: "trigger", type: "string", description: "Natural-language trigger phrase (for skills)", isRequired: false),
            ToolArgumentDescriptor(name: "description", type: "string", description: "Short description of what the skill/recipe does", isRequired: false),
            ToolArgumentDescriptor(name: "content", type: "string", description: "Full Markdown content or numbered step list", isRequired: false),
            ToolArgumentDescriptor(name: "explanation", type: "string", description: "Rationale for why this skill or edit is helpful", isRequired: false)
        ]
    }

    private let proposalStore: ProposalStore
    private let skillEngine: SkillEngine
    private let recipeEngine: RecipeEngine
    private let undoJournal: UndoJournal?

    public init(
        proposalStore: ProposalStore = .shared,
        skillEngine: SkillEngine = .shared,
        recipeEngine: RecipeEngine = .shared,
        undoJournal: UndoJournal? = nil
    ) {
        self.proposalStore = proposalStore
        self.skillEngine = skillEngine
        self.recipeEngine = recipeEngine
        self.undoJournal = undoJournal
    }

    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let rawName = (args["name"] ?? args["target_name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawName.isEmpty else {
            return ToolResult(success: false, message: "Missing required 'name' argument for skill/recipe proposal.")
        }

        let slug = rawName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".md", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/."))

        guard !slug.isEmpty, !slug.contains(".."), !slug.contains("/") else {
            return ToolResult(success: false, message: "Invalid target name '\(rawName)'. Use a plain filename slug like 'daily-digest'.")
        }

        let kindRaw = (args["target_kind"] ?? "skill").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let targetKind: ProposalTargetKind = (kindRaw == "recipe") ? .recipe : .skill

        let existingContent = await loadExistingMarkdown(slug: slug, kind: targetKind)
        let explicitChange = (args["change_type"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let changeType: ProposalChangeType
        switch explicitChange {
        case "delete":
            changeType = .delete
        case "edit":
            changeType = .edit
        case "create":
            changeType = .create
        default:
            changeType = (existingContent != nil) ? .edit : .create
        }

        let title = (args["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title.isEmpty ? "\(changeType.rawValue.capitalized) \(targetKind.rawValue) '\(slug)'" : title
        let explanation = (args["explanation"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedExplanation = explanation.isEmpty ? "Agent-proposed \(targetKind.rawValue) \(changeType.rawValue) awaiting human review." : explanation

        let newContent: String
        if changeType == .delete {
            newContent = ""
        } else {
            let rawContent = (args["content"] ?? args["new_content"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawContent.isEmpty else {
                return ToolResult(success: false, message: "Missing 'content' for \(changeType.rawValue) proposal '\(slug)'.")
            }
            newContent = formatMarkdownIfNeeded(
                slug: slug,
                kind: targetKind,
                trigger: args["trigger"],
                description: args["description"] ?? resolvedTitle,
                rawBody: rawContent
            )
        }

        do {
            let proposal = try proposalStore.createProposal(
                title: resolvedTitle,
                targetName: slug,
                targetKind: targetKind,
                changeType: changeType,
                oldContent: existingContent ?? "",
                newContent: newContent,
                explanation: resolvedExplanation
            )

            let propId = proposal.id
            let storeRef = self.proposalStore
            let undoAction: @Sendable () async throws -> Void = {
                _ = try? storeRef.rejectProposal(id: propId)
            }
            await (self.undoJournal ?? UndoJournal.shared).register(toolName: self.name, undoAction: undoAction)

            let message = """
            Staged \(targetKind.rawValue) proposal `\(proposal.id)` for review (`\(slug).md`, \(changeType.rawValue)):

            ```diff
            \(proposal.unifiedDiff())
            ```

            Run `pearl review approve \(proposal.id)` to apply or `pearl review reject \(proposal.id)` to discard.
            """
            return ToolResult(success: true, message: message, undoAction: undoAction)
        } catch {
            return ToolResult(success: false, message: "Failed to stage proposal: \(error.localizedDescription)")
        }
    }

    private func loadExistingMarkdown(slug: String, kind: ProposalTargetKind) async -> String? {
        let dir: URL = (kind == .recipe) ? recipeEngine.recipesDirectory : await skillEngine.skillsDirectory
        let fileURL = dir.appendingPathComponent("\(slug).md")
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    private func formatMarkdownIfNeeded(
        slug: String,
        kind: ProposalTargetKind,
        trigger: String?,
        description: String,
        rawBody: String
    ) -> String {
        if rawBody.hasPrefix("---") {
            return rawBody.hasSuffix("\n") ? rawBody : rawBody + "\n"
        }

        let cleanTrigger = (trigger ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTrigger = cleanTrigger.isEmpty ? slug.replacingOccurrences(of: "-", with: " ") : cleanTrigger
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)

        if kind == .recipe {
            return """
            ---
            name: \(slug)
            description: \(cleanDescription)
            triggers:
              - \(resolvedTrigger)
            inputs:
            ---
            \(rawBody)
            """
        }

        return """
        ---
        name: \(slug)
        trigger: \(resolvedTrigger)
        description: \(cleanDescription)
        ---
        \(rawBody)
        """
    }
}

// MARK: - UseRecipeTool

/// Loads and interpolates parameterized Markdown recipes (`{{variable}}`), or compiles them into a skill proposal.
public final class UseRecipeTool: PearlTool {
    public let name = "use_recipe"
    public let description = "Render a parameterized Markdown recipe by substituting {{variables}}, list recipes, or compile one into a reviewable skill proposal"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false

    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "name", type: "string", description: "Recipe name (or 'list' to enumerate installed recipes)", isRequired: true),
            ToolArgumentDescriptor(name: "arguments", type: "string", description: "JSON object or comma-separated key=value pairs for {{variable}} interpolation", isRequired: false),
            ToolArgumentDescriptor(name: "compile_to_skill", type: "string", description: "Set 'true' to compile the parameterized recipe into a Skill proposal in ProposalStore", isRequired: false)
        ]
    }

    private let recipeEngine: RecipeEngine
    private let proposalStore: ProposalStore

    public init(recipeEngine: RecipeEngine = .shared, proposalStore: ProposalStore = .shared) {
        self.recipeEngine = recipeEngine
        self.proposalStore = proposalStore
    }

    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        recipeEngine.ensureSeeded()

        let recipeName = (args["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipeName.isEmpty else {
            return ToolResult(success: false, message: "Missing required 'name' parameter for use_recipe.")
        }

        if recipeName.lowercased() == "list" {
            let recipes = recipeEngine.loadRecipes()
            if recipes.isEmpty {
                return ToolResult(success: true, message: "No recipes installed.")
            }
            let summary = recipes.map { r in
                let inputsText = r.inputs.isEmpty ? "none" : r.inputs.joined(separator: ", ")
                return "- **\(r.name)**: \(r.description) (inputs: \(inputsText))"
            }.joined(separator: "\n")
            return ToolResult(success: true, message: "Installed recipes:\n\(summary)")
        }

        let resolvedArgs = parseRecipeArguments(args: args)
        let compileFlag = (args["compile_to_skill"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if compileFlag == "true" || compileFlag == "1" {
            do {
                let proposal = try recipeEngine.compileToSkillProposal(
                    name: recipeName,
                    defaultArguments: resolvedArgs,
                    proposalStore: proposalStore
                )
                return ToolResult(
                    success: true,
                    message: "Compiled recipe '\(recipeName)' into skill proposal `\(proposal.id)`:\n\n```diff\n\(proposal.unifiedDiff())\n```"
                )
            } catch {
                return ToolResult(success: false, message: "Could not compile recipe '\(recipeName)': \(error.localizedDescription)")
            }
        }

        do {
            let rendered = try recipeEngine.renderRecipe(name: recipeName, arguments: resolvedArgs)
            return ToolResult(
                success: true,
                message: "Rendered recipe '\(recipeName)':\n\n\(rendered)"
            )
        } catch let error as RecipeEngineError {
            if case .missingRequiredInput(let missingKey) = error, let def = recipeEngine.readRecipe(name: recipeName) {
                return ToolResult(
                    success: false,
                    message: "Recipe '\(def.name)' requires input `\(missingKey)` (all inputs: \(def.inputs.joined(separator: ", "))). Provide arguments as JSON or `key=value`."
                )
            }
            return ToolResult(success: false, message: "Recipe error: \(error.localizedDescription)")
        } catch {
            return ToolResult(success: false, message: "Failed to render recipe '\(recipeName)': \(error.localizedDescription)")
        }
    }

    private func parseRecipeArguments(args: [String: String]) -> [String: String] {
        var resolved: [String: String] = [:]
        let reservedKeys: Set<String> = ["name", "arguments", "variables", "compile_to_skill"]

        for (k, v) in args where !reservedKeys.contains(k) {
            resolved[k] = v
        }

        guard let rawPayload = (args["arguments"] ?? args["variables"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPayload.isEmpty else {
            return resolved
        }

        if rawPayload.hasPrefix("{"), let data = rawPayload.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            for (k, v) in decoded {
                resolved[k] = v
            }
            return resolved
        }

        for pair in rawPayload.components(separatedBy: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if parts.count == 2, !parts[0].isEmpty {
                resolved[parts[0]] = parts[1]
            }
        }
        return resolved
    }
}

// MARK: - SearchSkillCatalogTool

/// Searches the built-in curated 16-blueprint skill catalog and locally installed Markdown skills.
public final class SearchSkillCatalogTool: PearlTool {
    public let name = "search_skill_catalog"
    public let description = "Search Pearl's built-in 16-blueprint skill catalog by keyword/category and list matching local skills"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false

    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "query", type: "string", description: "Search keyword across names, triggers, descriptions, and steps", isRequired: false),
            ToolArgumentDescriptor(name: "category", type: "string", description: "Category filter (Productivity, Research, Writing, Coding, System, Memory, Communication, Analysis)", isRequired: false),
            ToolArgumentDescriptor(name: "include_local", type: "string", description: "Include installed local skills (default true)", isRequired: false)
        ]
    }

    private let skillEngine: SkillEngine

    public init(skillEngine: SkillEngine = .shared) {
        self.skillEngine = skillEngine
    }

    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let query = (args["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawCategory = (args["category"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let category: String? = rawCategory.isEmpty ? nil : rawCategory
        let includeLocal = (args["include_local"] ?? "true").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "false"

        let blueprints = skillEngine.searchCatalog(query: query, category: category)
        var sections: [String] = []

        if includeLocal {
            await skillEngine.ensureSeeded()
            let localMatches = query.isEmpty
                ? await skillEngine.loadSkills()
                : await skillEngine.searchSkills(query: query)
            if !localMatches.isEmpty {
                let localLines = localMatches.map { s in
                    "- **\(s.name)** (trigger: \"\(s.trigger)\") — \(s.description)"
                }.joined(separator: "\n")
                sections.append("### Installed Local Skills (\(localMatches.count))\n\(localLines)")
            }
        }

        if blueprints.isEmpty {
            sections.append("### Built-in Skill Catalog\nNo catalog blueprints matched your filters.")
        } else {
            let catalogLines = blueprints.map { bp in
                let stepPreview = bp.steps.joined(separator: " -> ")
                return "- **\(bp.name)** [\(bp.category)] — \(bp.description)\n  Steps: \(stepPreview)"
            }.joined(separator: "\n")
            sections.append("### Built-in Skill Catalog (\(blueprints.count) matches)\n\(catalogLines)")
        }

        return ToolResult(success: true, message: sections.joined(separator: "\n\n"))
    }
}
