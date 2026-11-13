import Foundation

public struct UndoEntry: @unchecked Sendable {
    public let id: String
    public let toolName: String
    public let timestamp: Date
    public let action: @Sendable () async throws -> Void
    
    public init(toolName: String, action: @escaping @Sendable () async throws -> Void) {
        self.id = UUID().uuidString
        self.toolName = toolName
        self.timestamp = Date()
        self.action = action
    }
}

public actor UndoJournal {
    public static let shared = UndoJournal()
    
    private var stack: [UndoEntry] = []
    private let maxEntries: Int = 20
    
    public init() {}
    
    public func register(toolName: String, undoAction: @escaping @Sendable () async throws -> Void) {
        let entry = UndoEntry(toolName: toolName, action: undoAction)
        stack.append(entry)
        if stack.count > maxEntries {
            stack.removeFirst()
        }
    }
    
    public func undoLast() async throws -> String {
        guard let last = stack.popLast() else {
            return "Nothing to undo."
        }
        
        try await last.action()
        return "Undid last action (\(last.toolName))."
    }
    
    public func clear() {
        stack.removeAll()
    }
    
    public var count: Int {
        return stack.count
    }
}
