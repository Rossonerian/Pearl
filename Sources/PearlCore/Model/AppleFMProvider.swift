import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct FMStructuredIntent: Codable, Sendable {
    public let action: String
    public let parameter: String
    
    public init(action: String, parameter: String = "") {
        self.action = action
        self.parameter = parameter
    }
}

public enum AppleFMError: LocalizedError, Sendable {
    case unavailable(reason: String)
    case generationFailed(String)
    case escalationRequested
    case unsupportedFramework
    
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Apple Foundation Models unavailable on this system: \(reason)"
        case .generationFailed(let msg):
            return "Apple Foundation Models generation failed: \(msg)"
        case .escalationRequested:
            return "Task escalated to frontier model."
        case .unsupportedFramework:
            return "FoundationModels framework not supported on this OS version."
        }
    }
}

public final class AppleFMProvider: ModelProvider, @unchecked Sendable {
    public let name = "Apple FM"
    public let modelID = "SystemLanguageModel"
    public let isLocal = true
    public let maxAllowedTier = ToolTier.t2ReadPersonal
    
    // Test hook to simulate unavailability or failure for verification benchmarks
    public var isSimulatedUnavailable: Bool = false
    public var simulatedErrorReason: String? = nil
    
    public init() {}
    
    public var isAvailable: Bool {
        if isSimulatedUnavailable { return false }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }
    
    public func generate(prompt: String, context: ModelExecutionContext = ModelExecutionContext()) async throws -> ModelResponse {
        if isSimulatedUnavailable {
            throw AppleFMError.unavailable(reason: simulatedErrorReason ?? "Simulated failure for benchmark")
        }
        if context.forceEscalation {
            throw AppleFMError.escalationRequested
        }
        
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw AppleFMError.unsupportedFramework
        }
        
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw AppleFMError.unavailable(reason: "SystemLanguageModel availability: \(model.availability)")
        }
        
        // 1. Structured intent resolution for T0-T2 tools
        let intentInstructions = """
        You are Pearl local action resolver. Analyze the user request.
        If the request maps to one of the following tools, respond ONLY with a JSON object:
        {"action": "<volume|battery|open_app|close_app|screenshot|trash_screenshots|reminder|undo|unknown>", "parameter": "<value or empty>"}
        If the request is conversational, general knowledge, or requires reasoning/coding, return {"action": "unknown", "parameter": ""}.
        """
        
        let intentSession = LanguageModelSession(model: model, instructions: intentInstructions)
        do {
            let res = try await intentSession.respond(to: prompt)
            if let intent = parseIntentJSON(from: res.content), intent.action.lowercased() != "unknown" {
                let toolCall = mapIntentToToolCall(action: intent.action.lowercased(), parameter: intent.parameter)
                
                // Strictly enforce Tool Tier Rule: local model can only call T0-T2 tools.
                // The model NEVER picks its own tier; registered tool tier is checked against ToolRegistry.
                _ = try ToolTierEnforcer.validateToolCall(toolCall, providerIsLocal: true)
                
                let badge = HUDTurnBadge(
                    label: "on device",
                    provider: name,
                    modelID: modelID,
                    isLocal: true,
                    details: "tool: \(toolCall.toolName)"
                )
                
                return ModelResponse(
                    content: "Executing \(toolCall.toolName)...",
                    toolCalls: [toolCall],
                    usage: nil,
                    providerName: name,
                    modelID: modelID,
                    isLocal: true,
                    badge: badge
                )
            }
        } catch let tierError as ModelTierError {
            // Local model attempted to call a tool exceeding T2 tier; propagate for escalation or confirmation
            throw tierError
        } catch {
            // Fall through to conversational generation
        }
        
        // 2. Direct conversational generation
        let conversationalInstructions = context.systemPrompt ?? "You are Pearl, an intelligent, concise on-device voice assistant for Mac. Provide direct, helpful answers."
        let session = LanguageModelSession(model: model, instructions: conversationalInstructions)
        do {
            let res = try await session.respond(to: prompt)
            
            var tokenUsage: TokenUsage? = nil
            if #available(macOS 27.0, *) {
                let sessionUsage = session.usage
                tokenUsage = TokenUsage(
                    promptTokens: sessionUsage.input.totalTokenCount,
                    completionTokens: sessionUsage.output.totalTokenCount
                )
            }
            
            let badge = HUDTurnBadge(
                label: "on device",
                provider: name,
                modelID: modelID,
                isLocal: true,
                details: tokenUsage != nil ? "\(tokenUsage!.totalTokens) tokens" : nil
            )
            
            return ModelResponse(
                content: res.content,
                toolCalls: [],
                usage: tokenUsage,
                providerName: name,
                modelID: modelID,
                isLocal: true,
                badge: badge
            )
        } catch {
            throw AppleFMError.generationFailed(error.localizedDescription)
        }
        
        #else
        throw AppleFMError.unsupportedFramework
        #endif
    }
    
    public func stream(prompt: String, context: ModelExecutionContext = ModelExecutionContext()) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                if self.isSimulatedUnavailable {
                    continuation.finish(throwing: AppleFMError.unavailable(reason: self.simulatedErrorReason ?? "Simulated failure for benchmark"))
                    return
                }
                
                #if canImport(FoundationModels)
                guard #available(macOS 26.0, *) else {
                    continuation.finish(throwing: AppleFMError.unsupportedFramework)
                    return
                }
                let model = SystemLanguageModel.default
                guard model.availability == .available else {
                    continuation.finish(throwing: AppleFMError.unavailable(reason: "SystemLanguageModel unavailable"))
                    return
                }
                let session = LanguageModelSession(model: model, instructions: context.systemPrompt)
                do {
                    let stream = session.streamResponse(to: prompt)
                    var previousLength = 0
                    for try await snapshot in stream {
                        let current = snapshot.content
                        if current.count > previousLength {
                            let diffIndex = current.index(current.startIndex, offsetBy: previousLength)
                            let newChunk = String(current[diffIndex...])
                            continuation.yield(newChunk)
                            previousLength = current.count
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                #else
                continuation.finish(throwing: AppleFMError.unsupportedFramework)
                #endif
            }
        }
    }
    
    private func parseIntentJSON(from raw: String) -> FMStructuredIntent? {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```json") {
            clean = clean.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        } else if clean.hasPrefix("```") {
            clean = clean.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Find JSON bounds
        if let start = clean.firstIndex(of: "{"), let end = clean.lastIndex(of: "}") {
            let jsonSub = clean[start...end]
            if let data = String(jsonSub).data(using: .utf8),
               let parsed = try? JSONDecoder().decode(FMStructuredIntent.self, from: data) {
                return parsed
            }
        }
        return nil
    }
    
    private func mapIntentToToolCall(action: String, parameter: String) -> ModelToolCall {
        let param = parameter.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case "volume", "set_volume":
            return ModelToolCall(toolName: "volume", arguments: ["level": param.isEmpty ? "50" : param])
        case "battery", "get_battery":
            return ModelToolCall(toolName: "battery", arguments: [:])
        case "open_app", "launch_app":
            return ModelToolCall(toolName: "open_app", arguments: ["app": param])
        case "close_app", "quit_app":
            return ModelToolCall(toolName: "close_app", arguments: ["app": param])
        case "screenshot", "take_screenshot":
            return ModelToolCall(toolName: "screenshot", arguments: [:])
        case "trash_screenshots", "clean_screenshots":
            return ModelToolCall(toolName: "trash_screenshots", arguments: [:])
        case "reminder", "create_reminder":
            return ModelToolCall(toolName: "reminder", arguments: ["title": param])
        case "undo":
            return ModelToolCall(toolName: "undo", arguments: [:])
        default:
            return ModelToolCall(toolName: action, arguments: ["param": param])
        }
    }
}
