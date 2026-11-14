import Foundation

public enum ApprovalStatus: String, Codable, Sendable {
    case pending
    case approved
    case denied
}

public struct PendingApproval: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let jobId: String?
    public let toolName: String
    public let arguments: [String: String]
    public let tier: ToolTier
    public let reason: String
    public let createdAt: Date
    public var status: ApprovalStatus
    
    public init(
        id: String = UUID().uuidString,
        jobId: String? = nil,
        toolName: String,
        arguments: [String: String] = [:],
        tier: ToolTier,
        reason: String,
        createdAt: Date = Date(),
        status: ApprovalStatus = .pending
    ) {
        self.id = id
        self.jobId = jobId
        self.toolName = toolName
        self.arguments = arguments
        self.tier = tier
        self.reason = reason
        self.createdAt = createdAt
        self.status = status
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
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("Pearl", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
            url = dir.appendingPathComponent("approvals.json")
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
        jobId: String? = nil
    ) throws -> PendingApproval {
        let item = PendingApproval(
            id: UUID().uuidString,
            jobId: jobId,
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
        guard let tool = toolRegistry.tool(named: item.toolName) else {
            throw ApprovalQueueError.toolNotFound(item.toolName)
        }
        
        let context = ToolExecutionContext(
            trustState: .trusted,
            userConfirmed: true,
            providerIsLocal: true
        )
        
        let result = try await policyEngine.execute(tool: tool, args: item.arguments, context: context)
        
        items[index].status = .approved
        try save()
        
        return result
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
