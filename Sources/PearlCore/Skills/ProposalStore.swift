import Foundation

public enum ProposalTargetKind: String, Codable, Sendable {
    case skill
    case recipe
}

public enum ProposalChangeType: String, Codable, Sendable {
    case create
    case edit
    case delete
}

public enum ProposalStatus: String, Codable, Sendable {
    case pending
    case approved
    case rejected
}

public struct SkillProposal: Codable, Sendable, Equatable {
    public let id: String
    public var title: String
    public let targetName: String
    public let targetKind: ProposalTargetKind
    public let changeType: ProposalChangeType
    public var oldContent: String
    public var newContent: String
    public var explanation: String
    public var status: ProposalStatus
    public let createdAt: Date
    
    public init(
        id: String = UUID().uuidString,
        title: String,
        targetName: String,
        targetKind: ProposalTargetKind,
        changeType: ProposalChangeType,
        oldContent: String,
        newContent: String,
        explanation: String,
        status: ProposalStatus = .pending,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.targetName = targetName
        self.targetKind = targetKind
        self.changeType = changeType
        self.oldContent = oldContent
        self.newContent = newContent
        self.explanation = explanation
        self.status = status
        self.createdAt = createdAt
    }
    
    /// Generates standard unified diff lines between oldContent and newContent.
    public func unifiedDiff() -> String {
        let header = [
            "--- a/\(targetKind.rawValue)/\(targetName).md",
            "+++ b/\(targetKind.rawValue)/\(targetName).md"
        ]
        let oldLines = oldContent.isEmpty ? [] : oldContent.components(separatedBy: .newlines)
        let newLines = newContent.isEmpty ? [] : newContent.components(separatedBy: .newlines)
        
        if oldLines.isEmpty && newLines.isEmpty {
            return header.joined(separator: "\n")
        }
        
        if oldLines.isEmpty {
            var diff = header
            diff.append("@@ -0,0 +1,\(newLines.count) @@")
            for line in newLines {
                diff.append("+\(line)")
            }
            return diff.joined(separator: "\n")
        }
        
        if newLines.isEmpty {
            var diff = header
            diff.append("@@ -1,\(oldLines.count) +0,0 @@")
            for line in oldLines {
                diff.append("-\(line)")
            }
            return diff.joined(separator: "\n")
        }
        
        // Compute LCS for unified diff
        let m = oldLines.count
        let n = newLines.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0..<m {
            for j in 0..<n {
                if oldLines[i] == newLines[j] {
                    dp[i + 1][j + 1] = dp[i][j] + 1
                } else {
                    dp[i + 1][j + 1] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        
        var diffOps: [(type: Character, line: String)] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1] {
                diffOps.append((" ", oldLines[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                diffOps.append(("+", newLines[j - 1]))
                j -= 1
            } else if i > 0 && (j == 0 || dp[i][j - 1] < dp[i - 1][j]) {
                diffOps.append(("-", oldLines[i - 1]))
                i -= 1
            }
        }
        diffOps.reverse()
        
        var diff = header
        diff.append("@@ -1,\(oldLines.count) +1,\(newLines.count) @@")
        for op in diffOps {
            diff.append("\(op.type)\(op.line)")
        }
        return diff.joined(separator: "\n")
    }
}

public enum ProposalStoreError: Error, LocalizedError, Equatable {
    case proposalNotFound(String)
    case invalidTargetName(String)
    
    public var errorDescription: String? {
        switch self {
        case .proposalNotFound(let id): return "Proposal not found: '\(id)'"
        case .invalidTargetName(let name): return "Invalid proposal target name: '\(name)'"
        }
    }
}

/// Store managing candidate modifications to user skills and recipes.
public final class ProposalStore: @unchecked Sendable {
    public static let shared = ProposalStore()
    
    public static var defaultQueueFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Pearl", isDirectory: true)
            .appendingPathComponent("proposals", isDirectory: true)
            .appendingPathComponent("queue.json")
    }
    
    public let queueFileURL: URL
    private let lock = NSLock()
    private var proposals: [SkillProposal] = []
    
    public init(queueFileURL: URL? = nil) {
        self.queueFileURL = queueFileURL ?? Self.defaultQueueFileURL
        loadQueue()
    }
    
    /// Loads queued proposals from disk.
    private func loadQueue() {
        lock.lock()
        defer { lock.unlock() }
        
        guard FileManager.default.fileExists(atPath: queueFileURL.path),
              let data = try? Data(contentsOf: queueFileURL) else {
            return
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([SkillProposal].self, from: data) {
            self.proposals = decoded
        }
    }
    
    /// Writes the proposal queue atomically (.tmp file + rename).
    private func saveQueue() throws {
        let parentDir = queueFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(proposals)
        
        let tempURL = parentDir.appendingPathComponent(".\(queueFileURL.lastPathComponent).tmp")
        try data.write(to: tempURL, options: .atomic)
        
        if FileManager.default.fileExists(atPath: queueFileURL.path) {
            _ = try FileManager.default.replaceItemAt(queueFileURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: queueFileURL)
        }
    }
    
    /// Staged creation of a new skill or recipe proposal.
    @discardableResult
    public func createProposal(
        title: String,
        targetName: String,
        targetKind: ProposalTargetKind,
        changeType: ProposalChangeType,
        oldContent: String,
        newContent: String,
        explanation: String
    ) throws -> SkillProposal {
        let trimmed = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("..") else {
            throw ProposalStoreError.invalidTargetName(targetName)
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        let proposal = SkillProposal(
            title: title,
            targetName: trimmed,
            targetKind: targetKind,
            changeType: changeType,
            oldContent: oldContent,
            newContent: newContent,
            explanation: explanation,
            status: .pending,
            createdAt: Date()
        )
        proposals.append(proposal)
        try saveQueue()
        return proposal
    }
    
    /// Lists all pending proposals.
    public func listPending() -> [SkillProposal] {
        lock.lock()
        defer { lock.unlock() }
        return proposals.filter { $0.status == .pending }
    }
    
    /// Lists all proposals regardless of status.
    public func listAll() -> [SkillProposal] {
        lock.lock()
        defer { lock.unlock() }
        return proposals
    }
    
    /// Retrieves a single proposal by identifier.
    public func getProposal(id: String) -> SkillProposal? {
        lock.lock()
        defer { lock.unlock() }
        return proposals.first { $0.id == id }
    }
    
    /// Edits the proposed new content for a proposal.
    @discardableResult
    public func editProposal(id: String, newContent: String) throws -> SkillProposal {
        lock.lock()
        defer { lock.unlock() }
        
        guard let index = proposals.firstIndex(where: { $0.id == id }) else {
            throw ProposalStoreError.proposalNotFound(id)
        }
        
        proposals[index].newContent = newContent
        try saveQueue()
        return proposals[index]
    }
    
    /// Marks a proposal as rejected.
    @discardableResult
    public func rejectProposal(id: String) throws -> SkillProposal {
        lock.lock()
        defer { lock.unlock() }
        
        guard let index = proposals.firstIndex(where: { $0.id == id }) else {
            throw ProposalStoreError.proposalNotFound(id)
        }
        
        proposals[index].status = .rejected
        try saveQueue()
        return proposals[index]
    }
    
    /// Approves a proposal and executes the file update in the target directory.
    @discardableResult
    public func approveProposal(
        id: String,
        skillsDir: URL = SkillEngine.defaultSkillsDirectory,
        recipesDir: URL = RecipeEngine.defaultRecipesDirectory
    ) throws -> SkillProposal {
        lock.lock()
        defer { lock.unlock() }
        
        guard let index = proposals.firstIndex(where: { $0.id == id }) else {
            throw ProposalStoreError.proposalNotFound(id)
        }
        
        let proposal = proposals[index]
        let targetDir = proposal.targetKind == .skill ? skillsDir : recipesDir
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        
        let sanitizedName = proposal.targetName
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        let targetFileURL = targetDir.appendingPathComponent("\(sanitizedName).md")
        
        switch proposal.changeType {
        case .create, .edit:
            try proposal.newContent.write(to: targetFileURL, atomically: true, encoding: .utf8)
        case .delete:
            if FileManager.default.fileExists(atPath: targetFileURL.path) {
                try FileManager.default.removeItem(at: targetFileURL)
            }
        }
        
        proposals[index].status = .approved
        try saveQueue()
        
        if skillsDir == SkillEngine.defaultSkillsDirectory {
            SkillEngine.shared.invalidateIndex()
        }
        
        return proposals[index]
    }
}
