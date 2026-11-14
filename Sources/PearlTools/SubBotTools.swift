import Foundation
import PearlCore

// MARK: - SubBotRunTool

public final class SubBotRunTool: PearlTool {
    public let name = "subbot_run"
    public let description = "Execute a specialized web SubBot (search, scrape, crawl, map, monitor) to retrieve web content"
    public let tier = ToolTier.t2ReadPersonal
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    private let manager: SubBotManager
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "bot_type",
                type: "string",
                description: "SubBot operation: search, scrape, crawl, map, monitor",
                isRequired: true,
                allowedValues: ["search", "scrape", "crawl", "map", "monitor"]
            ),
            ToolArgumentDescriptor(
                name: "target",
                type: "string",
                description: "Target URL or comma-separated target URLs",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "url",
                type: "string",
                description: "Alternative parameter alias for target URL",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "query",
                type: "string",
                description: "Search query for search bot or starting query",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "max_depth",
                type: "string",
                description: "Maximum crawl depth (1-3, default 2)",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "limit",
                type: "string",
                description: "Maximum URLs or results to process (1-25, default 10)",
                isRequired: false
            )
        ]
    }
    
    public init(manager: SubBotManager = .shared) {
        self.manager = manager
    }
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let rawBotType = args["bot_type"]?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              let botType = SubBotType(rawValue: rawBotType) else {
            return ToolResult(
                success: false,
                message: "[UNTRUSTED WEB CONTENT]\nInvalid or missing 'bot_type'. Must be one of: search, scrape, crawl, map, monitor",
                trust: .untrusted
            )
        }
        
        let rawTarget = args["target"] ?? args["url"]
        let target = rawTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = args["query"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if botType == .search {
            if (query == nil || query!.isEmpty) && (target == nil || target!.isEmpty) {
                return ToolResult(
                    success: false,
                    message: "[UNTRUSTED WEB CONTENT]\nMissing required 'query' or 'target' for search bot.",
                    trust: .untrusted
                )
            }
        } else {
            if target == nil || target!.isEmpty {
                return ToolResult(
                    success: false,
                    message: "[UNTRUSTED WEB CONTENT]\nMissing required 'target' or 'url' for \(botType.rawValue) bot.",
                    trust: .untrusted
                )
            }
        }
        
        let targets: [String]
        if let t = target, !t.isEmpty {
            targets = t.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            targets = []
        }
        
        let maxDepth = Int(args["max_depth"] ?? "2") ?? 2
        let limit = Int(args["limit"] ?? "10") ?? 10
        
        let task = SubBotTask(
            botType: botType,
            targets: targets,
            query: query,
            maxDepth: maxDepth,
            limit: limit
        )
        
        let results = await manager.runBatch([task])
        guard let result = results.first else {
            return ToolResult(
                success: false,
                message: "[UNTRUSTED WEB CONTENT]\nSubBot execution produced no result.",
                trust: .untrusted
            )
        }
        
        TaintTracker.shared.markTainted(
            source: "subbot_run:\(botType.rawValue)",
            reason: "Ingested external web content via \(botType.rawValue) bot"
        )
        
        let message = "[UNTRUSTED WEB CONTENT]\n" + (result.success ? result.markdownContent : (result.error ?? "Execution failed."))
        return ToolResult(
            success: result.success,
            message: message,
            trust: .untrusted
        )
    }
}

// MARK: - SubBotWorkflowTool

public final class SubBotWorkflowTool: PearlTool {
    public let name = "subbot_workflow"
    public let description = "Execute a composite SubBot workflow (search_and_scrape, market_research, competitive_analysis)"
    public let tier = ToolTier.t2ReadPersonal
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    private let manager: SubBotManager
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "workflow",
                type: "string",
                description: "Workflow to execute: search_and_scrape, market_research, competitive_analysis",
                isRequired: true,
                allowedValues: ["search_and_scrape", "market_research", "competitive_analysis"]
            ),
            ToolArgumentDescriptor(
                name: "query",
                type: "string",
                description: "Search query for search_and_scrape / market_research",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "urls",
                type: "string",
                description: "Comma-separated target URLs for competitive_analysis",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "top_n",
                type: "string",
                description: "Number of top results to scrape (default 3)",
                isRequired: false
            )
        ]
    }
    
    public init(manager: SubBotManager = .shared) {
        self.manager = manager
    }
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let workflow = args["workflow"]?.trimmingCharacters(in: .whitespacesAndNewlines), !workflow.isEmpty else {
            return ToolResult(
                success: false,
                message: "[UNTRUSTED WEB CONTENT]\nMissing required 'workflow' parameter. Supported: search_and_scrape, market_research, competitive_analysis",
                trust: .untrusted
            )
        }
        
        let query = args["query"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlsString = args["urls"] ?? args["targets"] ?? args["url"]
        let urls = urlsString?.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let topN = Int(args["top_n"] ?? "3") ?? 3
        
        let result = await manager.executeWorkflow(
            name: workflow,
            query: query,
            urls: urls,
            topN: topN
        )
        
        TaintTracker.shared.markTainted(
            source: "subbot_workflow:\(workflow)",
            reason: "Ingested external web content via \(workflow) workflow"
        )
        
        let message = "[UNTRUSTED WEB CONTENT]\n" + (result.success ? result.markdownContent : (result.error ?? "Workflow execution failed."))
        return ToolResult(
            success: result.success,
            message: message,
            trust: .untrusted
        )
    }
}
