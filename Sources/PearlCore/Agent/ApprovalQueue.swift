import Foundation

public enum ApprovalStatus: String, Codable, Sendable {
    case pending
    case approved
    case denied
}

public struct PendingApproval: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let jobId: String?
    public let stepIndex: Int?
    public let toolName: String
    public let arguments: [String: String]
    public let tier: ToolTier
    public let reason: String
    public let createdAt: Date
    public var status: ApprovalStatus
    public var executionSucceeded: Bool?
    public var executionMessage: String?
    
    public init(
        id: String = UUID().uuidString,
        jobId: String? = nil,
        stepIndex: Int? = nil,
        toolName: String,
        arguments: [String: String] = [:],
        tier: ToolTier,
        reason: String,
        createdAt: Date = Date(),
        status: ApprovalStatus = .pending,
        executionSucceeded: Bool? = nil,
        executionMessage: String? = nil
    ) {
        self.id = id
        self.jobId = jobId
        self.stepIndex = stepIndex
        self.toolName = toolName
        self.arguments = arguments
        self.tier = tier
        self.reason = reason
        self.createdAt = createdAt
        self.status = status
        self.executionSucceeded = executionSucceeded
        self.executionMessage = executionMessage
    }
}

public enum ApprovalQueueError: Error, LocalizedError, Sendable {
    case itemNotFound(String)
    case alreadyResolved(String)
    case toolNotFound(String)
    case persistenceFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .itemNotFound(let id):
            return "Approval item not found with ID: \(id)"
        case .alreadyResolved(let id):
            return "Approval item already resolved with ID: \(id)"
        case .toolNotFound(let toolName):
            return "Tool not found in registry for approval: \(toolName)"
        case .persistenceFailed(let msg):
            return "Failed to persist approval queue: \(msg)"
        }
    }
}

public actor ApprovalQueue {
    public static let shared = ApprovalQueue()
    
    public nonisolated let storageURL: URL
    private let policyEngine: PolicyEngine
    private let toolRegistry: ToolRegistry
    private var items: [PendingApproval] = []
    
    public init(
        storageURL: URL? = nil,
        policyEngine: PolicyEngine = .shared,
        toolRegistry: ToolRegistry = .shared
    ) {
        let url: URL
        if let storageURL = storageURL {
            url = storageURL
        } else {
            url = PearlStoragePaths.fileURL(named: "approvals.json")
        }
        self.storageURL = url
        self.policyEngine = policyEngine
        self.toolRegistry = toolRegistry
        
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.items = (try? decoder.decode([PendingApproval].self, from: data)) ?? []
        } else {
            self.items = []
        }
    }
    
    @discardableResult
    public func enqueue(
        toolName: String,
        arguments: [String: String],
        tier: ToolTier,
        reason: String,
        jobId: String? = nil,
        stepIndex: Int? = nil
    ) throws -> PendingApproval {
        // Prevent duplicate pending approvals for the same plan step
        if let jobId = jobId, let stepIndex = stepIndex,
           let existing = items.first(where: { $0.jobId == jobId && $0.stepIndex == stepIndex && $0.status == .pending }) {
            return existing
        }
        
        let item = PendingApproval(
            id: UUID().uuidString,
            jobId: jobId,
            stepIndex: stepIndex,
            toolName: toolName,
            arguments: arguments,
            tier: tier,
            reason: reason,
            createdAt: Date(),
            status: .pending
        )
        items.append(item)
        try save()
        return item
    }
    
    public func listPending() -> [PendingApproval] {
        return items.filter { $0.status == .pending }
    }
    
    public func listAll() -> [PendingApproval] {
        return items
    }
    
    public func getApproval(id: String) -> PendingApproval? {
        return items.first { $0.id == id }
    }
    
    public func approve(id: String) async throws -> ToolResult {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw ApprovalQueueError.itemNotFound(id)
        }
        let item = items[index]
        guard item.status == .pending else {
            throw ApprovalQueueError.alreadyResolved(id)
        }
        let resolvedTool = toolRegistry.tool(named: item.toolName) ??
            (toolRegistry === ToolRegistry.shared ? CentralToolCatalog.shared.tool(named: item.toolName) : nil)
        guard let tool = resolvedTool else {
            throw ApprovalQueueError.toolNotFound(item.toolName)
        }
        
        // Mark as approved immediately before execution to prevent concurrent duplicate execution
        items[index].status = .approved
        try? save()
        
        let context = ToolExecutionContext(
            trustState: .trusted,
            userConfirmed: true,
            providerIsLocal: true,
            freshConfirmationArgs: item.arguments,
            freshConfirmationToolName: item.toolName
        )
        
        do {
            let result = try await policyEngine.execute(tool: tool, args: item.arguments, context: context)
            if let updatedIndex = items.firstIndex(where: { $0.id == id }) {
                items[updatedIndex].executionSucceeded = result.success
                items[updatedIndex].executionMessage = result.message
                try save()
            }
            return result
        } catch {
            if let updatedIndex = items.firstIndex(where: { $0.id == id }) {
                items[updatedIndex].executionSucceeded = false
                items[updatedIndex].executionMessage = error.localizedDescription
                try? save()
            }
            throw error
        }
    }
    
    @discardableResult
    public func deny(id: String) throws -> PendingApproval {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw ApprovalQueueError.itemNotFound(id)
        }
        guard items[index].status == .pending else {
            throw ApprovalQueueError.alreadyResolved(id)
        }
        
        items[index].status = .denied
        try save()
        
        return items[index]
    }
    
    public func clear() throws {
        items.removeAll()
        try save()
    }
    
    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(items)
            let dir = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
            try data.write(to: storageURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        } catch {
            throw ApprovalQueueError.persistenceFailed(error.localizedDescription)
        }
    }
}
