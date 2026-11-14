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

/// Actor orchestrating declarative Markdown user skills and multi-step macros.
public actor SkillEngine {
    public static let shared = SkillEngine()
    
    public let skillsDirectory: URL
    private var didEnsureSeeded = false
    
    public init(skillsDirectory: URL? = nil) {
        if let dir = skillsDirectory {
            self.skillsDirectory = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.skillsDirectory = appSupport
                .appendingPathComponent("Pearl", isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true)
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
    
    /// Matches normalized lowercased utterance against skill trigger or "run skill <name>".
    public func matchSkill(for utterance: String) -> SkillDefinition? {
        let normalized = utterance.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        
        let skills = loadSkills()
        for skill in skills {
            let trig = skill.trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let nameNoHyphens = name.replacingOccurrences(of: "-", with: " ")
            
            if normalized == trig {
                return skill
            }
            if normalized == "run skill \(name)" || normalized == "run skill \(nameNoHyphens)" ||
               normalized == "run \(name)" || normalized == "run \(nameNoHyphens)" ||
               normalized == "skill \(name)" || normalized == "skill \(nameNoHyphens)" {
                return skill
            }
        }
        return nil
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
            return
        }
        
        // Also search existing skills by loaded name
        let skills = loadSkills()
        if let match = skills.first(where: { $0.name.lowercased() == name.lowercased() }),
           let url = match.fileURL,
           FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
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
