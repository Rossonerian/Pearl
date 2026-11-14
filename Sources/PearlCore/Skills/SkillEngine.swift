import Foundation

/// Represents a single numbered step in a user skill / macro.
public struct SkillStepDefinition: Codable, Sendable, Equatable {
    public let index: Int
    public let description: String
    public let utterance: String
    
    public init(index: Int, description: String = "", utterance: String) {
        self.index = index
        self.description = description.isEmpty ? utterance : description
        self.utterance = utterance
    }
}

/// Represents a declarative user skill / macro loaded from human-readable Markdown.
public struct SkillDefinition: Codable, Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let trigger: String
    public let description: String
    public let steps: [SkillStepDefinition]
    public let fileURL: URL?
    
    public init(
        name: String,
        trigger: String,
        description: String,
        steps: [SkillStepDefinition],
        fileURL: URL? = nil
    ) {
        self.name = name
        self.trigger = trigger
        self.description = description
        self.steps = steps
        self.fileURL = fileURL
    }
}

public enum SkillEngineError: Error, LocalizedError, Sendable {
    case skillNotFound(String)
    case invalidSkillFormat(String)
    
    public var errorDescription: String? {
        switch self {
        case .skillNotFound(let name): return "Skill not found: '\(name)'"
        case .invalidSkillFormat(let msg): return "Invalid skill format: \(msg)"
        }
    }
}

/// Blueprint template for built-in skills in the Pearl catalog.
public struct CatalogSkillBlueprint: Codable, Sendable, Equatable {
    public let name: String
    public let category: String
    public let trigger: String
    public let description: String
    public let steps: [String]
    
    public init(
        name: String,
        category: String,
        trigger: String,
        description: String,
        steps: [String]
    ) {
        self.name = name
        self.category = category
        self.trigger = trigger
        self.description = description
        self.steps = steps
    }
}

/// Actor orchestrating declarative Markdown user skills and multi-step macros.
public actor SkillEngine {
    public static let shared = SkillEngine()
    
    public static var defaultSkillsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Pearl", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }
    
    public static let builtInCatalog: [CatalogSkillBlueprint] = [
        // Productivity (2)
        CatalogSkillBlueprint(
            name: "start-workday",
            category: "Productivity",
            trigger: "start my workday",
            description: "Check system readiness, calendar events, and top pending tasks",
            steps: ["check battery", "list tasks", "list calendar events"]
        ),
        CatalogSkillBlueprint(
            name: "meeting-prep",
            category: "Productivity",
            trigger: "prep for my meeting",
            description: "Prepare calendar context, urgent tasks, and clipboard preview",
            steps: ["list calendar events", "list tasks", "read clipboard"]
        ),
        
        // Research (2)
        CatalogSkillBlueprint(
            name: "topic-research",
            category: "Research",
            trigger: "research topic",
            description: "Perform deep research on a specified topic using web searches and synthesis",
            steps: ["search web for topic", "fetch top articles", "summarize findings"]
        ),
        CatalogSkillBlueprint(
            name: "competitive-analysis",
            category: "Research",
            trigger: "analyze competitor",
            description: "Track competitor updates, compare features, and compile briefing",
            steps: ["search competitor announcements", "extract feature comparison", "save briefing note"]
        ),
        
        // Writing (2)
        CatalogSkillBlueprint(
            name: "draft-newsletter",
            category: "Writing",
            trigger: "draft newsletter",
            description: "Compile weekly highlights, format sections, and review tone",
            steps: ["collect highlights", "draft sections", "review tone and format"]
        ),
        CatalogSkillBlueprint(
            name: "release-notes",
            category: "Writing",
            trigger: "generate release notes",
            description: "Collect recent git changes and draft structured release notes",
            steps: ["fetch git log", "group changes by category", "format markdown release notes"]
        ),
        
        // Coding (2)
        CatalogSkillBlueprint(
            name: "pr-review",
            category: "Coding",
            trigger: "review pull request",
            description: "Review git changes, run local test suite, and summarize feedback",
            steps: ["git status", "git diff", "swift test"]
        ),
        CatalogSkillBlueprint(
            name: "clean-build",
            category: "Coding",
            trigger: "clean build project",
            description: "Reset build caches, resolve dependencies, and compile target",
            steps: ["swift package clean", "swift package resolve", "swift test"]
        ),
        
        // System (2)
        CatalogSkillBlueprint(
            name: "system-health",
            category: "System",
            trigger: "check system health",
            description: "Inspect battery, storage capacity, and system status",
            steps: ["check battery", "check disk space", "list running processes"]
        ),
        CatalogSkillBlueprint(
            name: "focus-environment",
            category: "System",
            trigger: "setup focus mode",
            description: "Mute alerts, hide desktop distractions, and open focus timer",
            steps: ["mute audio", "hide desktop icons", "start focus timer"]
        ),
        
        // Memory (2)
        CatalogSkillBlueprint(
            name: "recall-context",
            category: "Memory",
            trigger: "recall recent context",
            description: "Query recent memories and summarize current working context",
            steps: ["query recent memories", "list active goals", "summarize working context"]
        ),
        CatalogSkillBlueprint(
            name: "archive-notes",
            category: "Memory",
            trigger: "archive stale notes",
            description: "Identify inactive notes, summarize key points, and move to archive",
            steps: ["scan inactive notes", "extract summaries", "move to archive directory"]
        ),
        
        // Communication (2)
        CatalogSkillBlueprint(
            name: "inbox-triage",
            category: "Communication",
            trigger: "triage my inbox",
            description: "Scan unread incoming messages and draft priority task list",
            steps: ["check unread messages", "filter urgent threads", "create follow-up tasks"]
        ),
        CatalogSkillBlueprint(
            name: "daily-standup",
            category: "Communication",
            trigger: "prep daily standup",
            description: "Summarize yesterday's work, today's plan, and potential blockers",
            steps: ["list completed items", "list today priorities", "draft standup update"]
        ),
        
        // Analysis (2)
        CatalogSkillBlueprint(
            name: "data-summary",
            category: "Analysis",
            trigger: "summarize data table",
            description: "Compute summary statistics and highlight outliers in data",
            steps: ["inspect data source", "compute key metrics", "format summary report"]
        ),
        CatalogSkillBlueprint(
            name: "log-audit",
            category: "Analysis",
            trigger: "audit error logs",
            description: "Scan logs for recurring errors and identify failure patterns",
            steps: ["read error log files", "group by error code", "generate incident summary"]
        )
    ]
    
    private static let stopWords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "and", "any", "are", "as", "at",
        "be", "because", "been", "before", "being", "below", "between", "both", "but", "by",
        "can", "could", "did", "do", "does", "doing", "down", "during",
        "each", "few", "for", "from", "further",
        "had", "has", "have", "having", "he", "her", "here", "hers", "herself", "him", "himself", "his", "how",
        "i", "if", "in", "into", "is", "it", "its", "itself",
        "just", "me", "more", "most", "my", "myself",
        "no", "nor", "not", "now", "of", "off", "on", "once", "only", "or", "other", "our", "ours", "ourselves", "out", "over", "own",
        "same", "she", "should", "so", "some", "such",
        "than", "that", "the", "their", "theirs", "them", "themselves", "then", "there", "these", "they", "this", "those", "through", "to", "too",
        "under", "until", "up", "very", "was", "we", "were", "what", "when", "where", "which", "while", "who", "whom", "why", "with", "would",
        "you", "your", "yours", "yourself", "yourselves"
    ]
    
    public let skillsDirectory: URL
    private var didEnsureSeeded = false
    
    // In-memory inverted keyword index protected by NSLock
    private let indexLock = NSLock()
    private nonisolated(unsafe) var triggerIndex: [String: Set<String>] = [:]
    private nonisolated(unsafe) var indexDirty: Bool = true
    private nonisolated(unsafe) var indexedDirectory: String?
    private nonisolated(unsafe) var cachedSkills: [SkillDefinition] = []
    
    public init(skillsDirectory: URL? = nil) {
        if let dir = skillsDirectory {
            self.skillsDirectory = dir
        } else {
            self.skillsDirectory = Self.defaultSkillsDirectory
        }
    }
    
    public func ensureSeeded() {
        guard !didEnsureSeeded else { return }
        didEnsureSeeded = true
        try? seedDefaultSkillsIfEmpty()
    }
    
    /// Seeds default human-readable markdown skills if the skills directory has zero `.md` files.
    public func seedDefaultSkillsIfEmpty() throws {
        try FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        
        let existingMD = (try? FileManager.default.contentsOfDirectory(at: skillsDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "md" } ?? []
            
        guard existingMD.isEmpty else { return }
        
        // 1. start-workday.md
        let startWorkday = """
        ---
        name: start-workday
        trigger: start my workday
        description: Check system readiness, calendar events, and top pending tasks
        ---
        1. check battery
        2. list tasks
        3. list calendar events
        """
        let startWorkdayURL = skillsDirectory.appendingPathComponent("start-workday.md")
        try startWorkday.write(to: startWorkdayURL, atomically: true, encoding: .utf8)
        
        // 2. meeting-prep.md
        let meetingPrep = """
        ---
        name: meeting-prep
        trigger: prep for my meeting
        description: Prepare calendar context, urgent tasks, and clipboard preview
        ---
        1. list calendar events
        2. list tasks
        3. read clipboard
        """
        let meetingPrepURL = skillsDirectory.appendingPathComponent("meeting-prep.md")
        try meetingPrep.write(to: meetingPrepURL, atomically: true, encoding: .utf8)
        
        invalidateIndex()
    }
    
    /// Invalidates the in-memory inverted trigger keyword index.
    public nonisolated func invalidateIndex() {
        indexLock.lock()
        defer { indexLock.unlock() }
        indexDirty = true
    }
    
    /// Rebuilds the in-memory inverted keyword index if marked dirty or uninitialized.
    @discardableResult
    public func rebuildIndexIfNeeded() -> [SkillDefinition] {
        indexLock.lock()
        if !indexDirty && indexedDirectory == skillsDirectory.path {
            let existing = cachedSkills
            indexLock.unlock()
            return existing
        }
        indexLock.unlock()
        
        let skills = loadSkills()
        var newIndex: [String: Set<String>] = [:]
        
        for skill in skills {
            let nameTokens = Self.tokenize(skill.name.replacingOccurrences(of: "-", with: " "))
            let triggerTokens = Self.tokenize(skill.trigger)
            let descTokens = Self.tokenize(skill.description)
            let stepTokens = skill.steps.flatMap { Self.tokenize($0.description) + Self.tokenize($0.utterance) }
            
            let allTokens = Set(nameTokens + triggerTokens + descTokens + stepTokens)
            for token in allTokens {
                newIndex[token, default: []].insert(skill.name)
            }
        }
        
        indexLock.lock()
        self.triggerIndex = newIndex
        self.cachedSkills = skills
        self.indexedDirectory = skillsDirectory.path
        self.indexDirty = false
        indexLock.unlock()
        
        return skills
    }
    
    /// Loads all skills from markdown files in the skills directory.
    public func loadSkills() -> [SkillDefinition] {
        guard FileManager.default.fileExists(atPath: skillsDirectory.path) else {
            return []
        }
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: skillsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        
        var loaded: [SkillDefinition] = []
        for file in files where file.pathExtension.lowercased() == "md" {
            if let skill = parseSkillFile(at: file) {
                loaded.append(skill)
            }
        }
        
        return loaded.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
    
    /// Finds a skill matching the given utterance using exact match or inverted index scoring.
    public func findSkillByTrigger(_ utterance: String) -> (skill: SkillDefinition, score: Double)? {
        let normalized = utterance.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        
        let skills = rebuildIndexIfNeeded()
        
        // 1. Exact match against trigger or "run skill <name>", "run <name>", "skill <name>"
        for skill in skills {
            let trig = skill.trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let nameNoHyphens = name.replacingOccurrences(of: "-", with: " ")
            
            if normalized == trig ||
               normalized == "run skill \(name)" || normalized == "run skill \(nameNoHyphens)" ||
               normalized == "run \(name)" || normalized == "run \(nameNoHyphens)" ||
               normalized == "skill \(name)" || normalized == "skill \(nameNoHyphens)" {
                return (skill, 1.0)
            }
        }
        
        // 2. Tokenize utterance and lookup candidates in inverted index (O(1) per token)
        let uttTokens = Set(Self.tokenize(normalized))
        guard !uttTokens.isEmpty else { return nil }
        
        indexLock.lock()
        var candidateNames: Set<String> = []
        for token in uttTokens {
            if let names = triggerIndex[token] {
                candidateNames.formUnion(names)
            }
        }
        indexLock.unlock()
        
        guard !candidateNames.isEmpty else { return nil }
        
        var bestSkill: SkillDefinition?
        var bestScore: Double = 0.0
        
        for name in candidateNames {
            guard let skill = skills.first(where: { $0.name == name }) else { continue }
            
            let triggerTokens = Set(Self.tokenize(skill.trigger))
            let overlapCount = uttTokens.intersection(triggerTokens).count
            let triggerTokenCount = triggerTokens.count
            
            var score = Double(overlapCount) / Double(max(1, triggerTokenCount))
            
            // Exact phrase bonus if utterance contains full trigger phrase or vice-versa
            let normTrig = skill.trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.contains(normTrig) {
                score += 0.25
            } else if normTrig.contains(normalized) {
                score += 0.15
            }
            
            score = min(1.0, score)
            
            if score > bestScore {
                bestScore = score
                bestSkill = skill
            }
        }
        
        if let skill = bestSkill, bestScore >= 0.6 {
            return (skill, bestScore)
        }
        
        return nil
    }
    
    /// Matches normalized lowercased utterance against skill trigger or "run skill <name>".
    public func matchSkill(for utterance: String) -> SkillDefinition? {
        return findSkillByTrigger(utterance)?.skill
    }
    
    /// Searches available skills using inverted index keyword overlap and relevance scoring.
    public func searchSkills(query: String) -> [SkillDefinition] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        
        let skills = rebuildIndexIfNeeded()
        let queryTokens = Set(Self.tokenize(trimmed))
        guard !queryTokens.isEmpty else { return [] }
        
        indexLock.lock()
        var candidateNames: Set<String> = []
        for token in queryTokens {
            if let names = triggerIndex[token] {
                candidateNames.formUnion(names)
            }
        }
        indexLock.unlock()
        
        var scored: [(skill: SkillDefinition, score: Double)] = []
        for name in candidateNames {
            guard let skill = skills.first(where: { $0.name == name }) else { continue }
            
            let nameTokens = Set(Self.tokenize(skill.name.replacingOccurrences(of: "-", with: " ")))
            let triggerTokens = Set(Self.tokenize(skill.trigger))
            let descTokens = Set(Self.tokenize(skill.description))
            let stepTokens = Set(skill.steps.flatMap { Self.tokenize($0.description) + Self.tokenize($0.utterance) })
            let allSkillTokens = nameTokens.union(triggerTokens).union(descTokens).union(stepTokens)
            
            let overlap = queryTokens.intersection(allSkillTokens).count
            var score = Double(overlap) / Double(max(1, queryTokens.count))
            
            if skill.name.lowercased().contains(trimmed) || skill.trigger.lowercased().contains(trimmed) {
                score += 0.5
            }
            if skill.description.lowercased().contains(trimmed) {
                score += 0.25
            }
            if skill.steps.contains(where: { $0.utterance.lowercased().contains(trimmed) || $0.description.lowercased().contains(trimmed) }) {
                score += 0.2
            }
            
            if score > 0 {
                scored.append((skill, score))
            }
        }
        
        scored.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.skill.name.lowercased() < $1.skill.name.lowercased()
        }
        
        return scored.map { $0.skill }
    }
    
    /// Searches the built-in skill catalog by query and optional category.
    public nonisolated func searchCatalog(query: String, category: String? = nil) -> [CatalogSkillBlueprint] {
        let pool: [CatalogSkillBlueprint]
        if let cat = category?.trimmingCharacters(in: .whitespacesAndNewlines), !cat.isEmpty {
            pool = Self.builtInCatalog.filter { $0.category.caseInsensitiveCompare(cat) == .orderedSame }
        } else {
            pool = Self.builtInCatalog
        }
        
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedQuery.isEmpty else {
            return pool
        }
        
        let queryTokens = Set(Self.tokenize(trimmedQuery))
        
        var scored: [(bp: CatalogSkillBlueprint, score: Double)] = []
        for bp in pool {
            let nameTokens = Set(Self.tokenize(bp.name.replacingOccurrences(of: "-", with: " ")))
            let trigTokens = Set(Self.tokenize(bp.trigger))
            let descTokens = Set(Self.tokenize(bp.description))
            let stepTokens = Set(bp.steps.flatMap { Self.tokenize($0) })
            let allTokens = nameTokens.union(trigTokens).union(descTokens).union(stepTokens)
            
            let overlap = queryTokens.intersection(allTokens).count
            var score = queryTokens.isEmpty ? 0.0 : Double(overlap) / Double(max(1, queryTokens.count))
            
            if bp.name.lowercased().contains(trimmedQuery) || bp.trigger.lowercased().contains(trimmedQuery) {
                score += 0.5
            }
            if bp.description.lowercased().contains(trimmedQuery) {
                score += 0.25
            }
            
            if score > 0 {
                scored.append((bp, score))
            }
        }
        
        scored.sort {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.bp.name.lowercased() < $1.bp.name.lowercased()
        }
        
        return scored.map { $0.bp }
    }
    
    /// Tokenizes input text into lowercase alphanumeric tokens >= 2 chars, filtering stop words.
    public static func tokenize(_ text: String, filterStopWords: Bool = true) -> [String] {
        let lower = text.lowercased()
        let rawTokens = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return rawTokens.compactMap { token in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return nil }
            if filterStopWords && stopWords.contains(trimmed) { return nil }
            return trimmed
        }
    }
    
    /// Saves a skill definition as a human-readable markdown file in the skills directory.
    @discardableResult
    public func saveSkill(_ skill: SkillDefinition) throws -> URL {
        try FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        
        let sanitizedName = skill.name
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        let fileURL = skillsDirectory.appendingPathComponent("\(sanitizedName).md")
        
        var lines: [String] = []
        lines.append("---")
        lines.append("name: \(skill.name)")
        lines.append("trigger: \(skill.trigger)")
        lines.append("description: \(skill.description)")
        lines.append("---")
        
        let sortedSteps = skill.steps.sorted { $0.index < $1.index }
        for step in sortedSteps {
            if step.description != step.utterance && !step.description.isEmpty {
                lines.append("\(step.index). \(step.description) - \(step.utterance)")
            } else {
                lines.append("\(step.index). \(step.utterance)")
            }
        }
        
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        
        invalidateIndex()
        return fileURL
    }
    
    /// Deletes a skill by name.
    public func deleteSkill(name: String) throws {
        let sanitizedName = name
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        
        let fileURL = skillsDirectory.appendingPathComponent("\(sanitizedName).md")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
            invalidateIndex()
            return
        }
        
        // Also search existing skills by loaded name
        let skills = loadSkills()
        if let match = skills.first(where: { $0.name.lowercased() == name.lowercased() }),
           let url = match.fileURL,
           FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            invalidateIndex()
            return
        }
        
        throw SkillEngineError.skillNotFound(name)
    }
    
    // MARK: - Markdown Parsing
    
    private func parseSkillFile(at fileURL: URL) -> SkillDefinition? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        
        let lines = content.components(separatedBy: .newlines)
        var name: String?
        var trigger: String?
        var description: String?
        var steps: [SkillStepDefinition] = []
        
        var inFrontmatter = false
        var frontmatterEncountered = false
        var stepIndexCounter = 1
        
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            
            if line == "---" {
                if !frontmatterEncountered {
                    inFrontmatter = true
                    frontmatterEncountered = true
                    continue
                } else if inFrontmatter {
                    inFrontmatter = false
                    continue
                }
            }
            
            if inFrontmatter || !frontmatterEncountered {
                if line.lowercased().hasPrefix("name:") {
                    let val = String(line.dropFirst("name:".count)).trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty { name = val }
                    continue
                } else if line.lowercased().hasPrefix("trigger:") {
                    let val = String(line.dropFirst("trigger:".count)).trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty { trigger = val }
                    continue
                } else if line.lowercased().hasPrefix("description:") {
                    let val = String(line.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty { description = val }
                    continue
                }
            }
            
            // Check for numbered step: e.g. "1. check battery" or "1) check battery"
            let stepRegex = try? NSRegularExpression(pattern: #"^(\d+)[\.\)]\s*(.*)$"#)
            let nsLine = line as NSString
            if let match = stepRegex?.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                let indexStr = nsLine.substring(with: match.range(at: 1))
                let stepBody = nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let idx = Int(indexStr) ?? stepIndexCounter
                
                let stepDesc: String
                let stepUtt: String
                
                if stepBody.contains(" - ") {
                    let parts = stepBody.components(separatedBy: " - ")
                    stepDesc = parts[0].trimmingCharacters(in: .whitespaces)
                    stepUtt = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
                } else if stepBody.contains(": ") {
                    let parts = stepBody.components(separatedBy: ": ")
                    stepDesc = parts[0].trimmingCharacters(in: .whitespaces)
                    stepUtt = parts.dropFirst().joined(separator: ": ").trimmingCharacters(in: .whitespaces)
                } else {
                    stepDesc = stepBody
                    stepUtt = stepBody
                }
                
                steps.append(SkillStepDefinition(index: idx, description: stepDesc, utterance: stepUtt))
                stepIndexCounter = idx + 1
            }
        }
        
        let finalName = name ?? fileURL.deletingPathExtension().lastPathComponent
        let finalTrigger = trigger ?? finalName
        let finalDescription = description ?? finalName
        
        return SkillDefinition(
            name: finalName,
            trigger: finalTrigger,
            description: finalDescription,
            steps: steps.sorted { $0.index < $1.index },
            fileURL: fileURL
        )
    }
}
