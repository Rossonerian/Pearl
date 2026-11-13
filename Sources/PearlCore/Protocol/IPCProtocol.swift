import Foundation

public struct IPCRequest: Codable, Sendable {
    public let id: String
    public let command: String
    public let arguments: [String: String]?
    
    public init(id: String = UUID().uuidString, command: String, arguments: [String: String]? = nil) {
        self.id = id
        self.command = command
        self.arguments = arguments
    }
}

public struct IPCResponse: Codable, Sendable {
    public let id: String
    public let success: Bool
    public let message: String
    public let data: [String: String]?
    public let latencyMs: Double?
    
    public init(id: String, success: Bool, message: String, data: [String: String]? = nil, latencyMs: Double? = nil) {
        self.id = id
        self.success = success
        self.message = message
        self.data = data
        self.latencyMs = latencyMs
    }
}
