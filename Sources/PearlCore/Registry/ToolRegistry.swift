import Foundation

public final class ToolRegistry: @unchecked Sendable {
    public static let shared = ToolRegistry()
    
    private var tools: [String: any PearlTool] = [:]
    private let lock = NSLock()
    
    public init() {}
    
    public func register(_ tool: any PearlTool) {
        lock.lock()
        defer { lock.unlock() }
        tools[tool.name.lowercased()] = tool
    }
    
    public func tool(named name: String) -> (any PearlTool)? {
        lock.lock()
        defer { lock.unlock() }
        return tools[name.lowercased()]
    }
    
    public func allTools() -> [any PearlTool] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tools.values)
    }
}
