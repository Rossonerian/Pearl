import Foundation

/// Subagent specialist archetypes tailored for targeted problem domains.
public enum SpecialistArchetype: String, Codable, CaseIterable, Sendable {
    case athena
    case artemis
    case mnemosyne
    case sisyphus
    
    public var displayName: String {
        switch self {
        case .athena:
            return "Athena (Planner)"
        case .artemis:
            return "Artemis (Researcher)"
        case .mnemosyne:
            return "Mnemosyne (Vault Curator)"
        case .sisyphus:
            return "Sisyphus (Batch Executor)"
        }
    }
    
    public var domain: String {
        switch self {
        case .athena:
            return "Strategic Planning & Decomposition"
        case .artemis:
            return "Deep Research & Web/Code Investigation"
        case .mnemosyne:
            return "Vault Knowledge & Memory Curation"
        case .sisyphus:
            return "Batch Execution & Repetitive Workflows"
        }
    }
    
    public var preferredTools: [String] {
        switch self {
        case .athena:
            return ["plan_create", "plan_analyze", "task_breakdown", "approval_request"]
        case .artemis:
            return ["web_search", "fetch_url", "code_search", "file_read"]
        case .mnemosyne:
            return ["vault_search", "memory_query", "context_recall", "note_read"]
        case .sisyphus:
            return ["batch_run", "shell_exec", "file_transform", "loop_step"]
        }
    }
    
    public var systemDirective: String {
        switch self {
        case .athena:
            return "You are Athena, specialist planner and strategist. Decompose complex user goals into rigorous, dependency-aware execution steps. Anticipate failure modes and ensure deterministic progress."
        case .artemis:
            return "You are Artemis, specialist researcher and investigative agent. Relentlessly pursue answers across web and local sources, cross-verify claims, and present synthesized findings with citations."
        case .mnemosyne:
            return "You are Mnemosyne, specialist vault curator and memory custodian. Maintain long-term context, organize knowledge entries, and retrieve relevant historical context without omission."
        case .sisyphus:
            return "You are Sisyphus, specialist batch executor. Drive repetitive operations and multi-step tasks to completion with fault tolerance, idempotency, and rigorous step-by-step reporting."
        }
    }
    
    /// Parses an utterance starting with an archetype handle (e.g. `@athena ...`, `@sissyphous ...`).
    /// Returns the detected archetype and the cleaned remainder of the query, or `nil` if no valid prefix matches.
    public static func parsePrefix(from utterance: String) -> (archetype: SpecialistArchetype, strippedQuery: String)? {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@") else { return nil }
        
        let pattern = #"^@(athena|artemis|mnemosyne|sisyphus|sissyphous)\b[:,\s]*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)) else {
            return nil
        }
        
        guard let nameRange = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        let matchedName = String(trimmed[nameRange]).lowercased()
        
        let archetype: SpecialistArchetype
        switch matchedName {
        case "athena":
            archetype = .athena
        case "artemis":
            archetype = .artemis
        case "mnemosyne":
            archetype = .mnemosyne
        case "sisyphus", "sissyphous":
            archetype = .sisyphus
        default:
            return nil
        }
        
        let queryRange = Range(match.range(at: 2), in: trimmed)
        let rawQuery = queryRange.map { String(trimmed[$0]) } ?? ""
        let cleanedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return (archetype, cleanedQuery)
    }
}

/// Crash-proof Markdown execution report ledger implementing the SUBAGENT_CONTRACT.md protocol.
public final class SubagentReportLedger: @unchecked Sendable {
    public static let shared = SubagentReportLedger()
    
    public let reportsDirectory: URL
    private let lock = NSLock()
    
    public init(reportsDirectory: URL? = nil) {
        if let dir = reportsDirectory {
            self.reportsDirectory = dir
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.reportsDirectory = base.appendingPathComponent("Pearl/reports")
        }
        try? FileManager.default.createDirectory(at: self.reportsDirectory, withIntermediateDirectories: true)
    }
    
    /// Starts a new subagent execution report on disk.
    @discardableResult
    public func startReport(jobId: String, archetype: SpecialistArchetype?, goal: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        
        let fileURL = reportFileURL(for: jobId)
        let isoDate = ISO8601DateFormatter().string(from: Date())
        let archetypeName = archetype?.displayName ?? "General"
        let header = "STARTED: \(isoDate) | Archetype: \(archetypeName) | Goal: \(goal)\n\n## Execution Log\n"
        
        try header.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
    
    /// Appends a step execution record to the active report with disk flush.
    public func appendStep(
        jobId: String,
        stepIndex: Int,
        totalSteps: Int,
        toolName: String,
        status: String,
        detail: String,
        durationMs: Double? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let fileURL = reportFileURL(for: jobId)
        let durationPart = durationMs.map { String(format: " (%.1fms)", $0) } ?? ""
        let entry = "- Step \(stepIndex)/\(totalSteps): [\(status)] tool=\(toolName)\(durationPart) - \(detail)\n"
        
        try appendData(entry.data(using: .utf8) ?? Data(), to: fileURL)
    }
    
    /// Finalizes the report with status, summary, and verification details.
    public func finalizeReport(jobId: String, status: String, summary: String, verification: String) throws {
        lock.lock()
        defer { lock.unlock() }
        
        let fileURL = reportFileURL(for: jobId)
        let finalSection = """
        
        ## Final Report
        Status: \(status)
        Summary: \(summary)
        Verification: \(verification)
        
        """
        
        try appendData(finalSection.data(using: .utf8) ?? Data(), to: fileURL)
    }
    
    /// Reads the raw Markdown report for a given job.
    public func readReport(jobId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        
        let fileURL = reportFileURL(for: jobId)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }
    
    /// Lists all `.md` subagent reports present in the reports directory.
    public func listReports() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    
    // MARK: - Private Helpers
    
    private func reportFileURL(for jobId: String) -> URL {
        let sanitizedId = jobId.replacingOccurrences(of: "/", with: "_")
        let fileName = sanitizedId.hasSuffix(".md") ? sanitizedId : "\(sanitizedId).md"
        return reportsDirectory.appendingPathComponent(fileName)
    }
    
    private func appendData(_ data: Data, to fileURL: URL) throws {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
