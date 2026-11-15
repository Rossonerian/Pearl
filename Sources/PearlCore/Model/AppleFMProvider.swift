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

private struct FMToolCallPayload: Codable {
    let tool: String?
    let action: String?
    let parameter: String?
    let arguments: [String: String]?
    let steps: [FMPlanStepPayload]?
}

private struct FMPlanStepPayload: Codable {
    let tool: String?
    let action: String?
    let arguments: [String: String]?
    let parameter: String?
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
    public let maxAllowedTier = ToolTier.t3WorkspaceChanges
    
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
        
        // 1. Dynamic structured intent & multi-arg tool resolution from CentralToolCatalog
        let toolCatalogSummary = buildDynamicToolPromptSummary()
        let intentInstructions = """
        You are Pearl local action resolver. Analyze the user request and available native tools.
        Available tools:
        \(toolCatalogSummary)
        
        Respond ONLY with valid JSON using one of these shapes:
        - Single tool call: {"tool": "<tool_name>", "arguments": {"arg": "value"}}
        - Multi-step plan: {"steps": [{"tool": "<tool_name>", "arguments": {"arg": "value"}}]}
        - Conversational / general question / unsupported action: {"tool": "none", "arguments": {}}
        """
        
        let intentSession = LanguageModelSession(model: model, instructions: intentInstructions)
        do {
            let res = try await intentSession.respond(to: prompt)
            let toolCalls = parseToolCalls(from: res.content)
            if !toolCalls.isEmpty {
                for call in toolCalls {
                    _ = try ToolTierEnforcer.validateToolCall(
                        call,
                        providerIsLocal: true,
                        trustState: context.trustState
                    )
                }
                
                let namesSummary = toolCalls.map(\.toolName).joined(separator: ", ")
                let badge = HUDTurnBadge(
                    label: "",
                    provider: name,
                    modelID: modelID,
                    isLocal: true,
                    details: toolCalls.count == 1 ? "tool: \(namesSummary)" : "plan: \(toolCalls.count) steps"
                )
                
                return ModelResponse(
                    content: "Executing \(namesSummary)...",
                    toolCalls: toolCalls,
                    usage: nil,
                    providerName: name,
                    modelID: modelID,
                    isLocal: true,
                    badge: badge
                )
            }
        } catch let tierError as ModelTierError {
            throw tierError
        } catch {
            // Fall through to conversational generation
        }
        
        // 2. Direct conversational generation
        var conversationalInstructions = context.systemPrompt ?? "You are Pearl, an intelligent, concise on-device voice assistant for Mac. Provide direct, helpful answers."
        if let history = context.conversationHistory, !history.isEmpty {
            let historyText = history.map { "User: \($0.cleanedInput)\nAssistant: \($0.assistantResponse)" }.joined(separator: "\n")
            conversationalInstructions += "\n\nRecent conversation history:\n" + historyText
        }
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
                label: "",
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
    
    private func buildDynamicToolPromptSummary() -> String {
        let exposed = CentralToolCatalog.shared.exposedTools(for: .nativeAssistant)
        if exposed.isEmpty {
            return "- create_directory(path*, recursive, create_if_missing)\n- list_directory(path*, recursive, limit, filter)\n- search_files(query, folder, extension)\n- copy_file(source*, destination*)\n- move_file(source*, destination*, confirm)\n- rename_file(source*, destination*, confirm)\n- trash_file(path*, confirm)\n- volume(level)\n- battery()\n- open_app(app*)\n- close_app(app*)\n- reminder(action, title, id)\n- list_tasks(status)\n- create_task(title*)\n- complete_task(id*)\n- undo()"
        }
        let lines: [String] = exposed.prefix(38).map { tool in
            let meta = CentralToolCatalog.shared.metadata(for: tool.name)
            let args = (meta?.arguments ?? tool.argumentDescriptors).map { desc in
                desc.isRequired ? "\(desc.name)*" : desc.name
            }.joined(separator: ", ")
            return "- \(tool.name)(\(args))"
        }
        return lines.joined(separator: "\n")
    }
    
    private func parseToolCalls(from raw: String) -> [ModelToolCall] {
        guard let jsonSub = extractJSONSubstring(from: raw),
              let data = jsonSub.data(using: .utf8) else {
            return []
        }
        if let payload = try? JSONDecoder().decode(FMToolCallPayload.self, from: data) {
            if let steps = payload.steps, !steps.isEmpty {
                return steps.compactMap { step in
                    if let tool = step.tool?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !tool.isEmpty, tool.lowercased() != "none", tool.lowercased() != "unknown" {
                        return ModelToolCall(toolName: tool, arguments: step.arguments ?? [:])
                    }
                    if let action = step.action?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !action.isEmpty, action.lowercased() != "none", action.lowercased() != "unknown" {
                        return mapIntentToToolCall(action: action.lowercased(), parameter: step.parameter ?? "")
                    }
                    return nil
                }
            }
            if let tool = payload.tool?.trimmingCharacters(in: .whitespacesAndNewlines),
               !tool.isEmpty, tool.lowercased() != "none", tool.lowercased() != "unknown" {
                return [ModelToolCall(toolName: tool, arguments: payload.arguments ?? [:])]
            }
            if let action = payload.action?.trimmingCharacters(in: .whitespacesAndNewlines),
               !action.isEmpty, action.lowercased() != "none", action.lowercased() != "unknown" {
                if let args = payload.arguments, !args.isEmpty {
                    return [ModelToolCall(toolName: action, arguments: args)]
                }
                return [mapIntentToToolCall(action: action.lowercased(), parameter: payload.parameter ?? "")]
            }
        }
        if let legacy = parseIntentJSON(from: raw),
           legacy.action.lowercased() != "unknown",
           legacy.action.lowercased() != "none" {
            return [mapIntentToToolCall(action: legacy.action.lowercased(), parameter: legacy.parameter)]
        }
        return []
    }
    
    private func extractJSONSubstring(from raw: String) -> String? {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```json") {
            clean = clean.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        } else if clean.hasPrefix("```") {
            clean = clean.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = clean.firstIndex(of: "{"), let end = clean.lastIndex(of: "}") {
            return String(clean[start...end])
        }
        return nil
    }
    
    private func parseIntentJSON(from raw: String) -> FMStructuredIntent? {
        guard let jsonSub = extractJSONSubstring(from: raw),
              let data = jsonSub.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(FMStructuredIntent.self, from: data) else {
            return nil
        }
        return parsed
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
        case "list_tasks":
            return ModelToolCall(toolName: "list_tasks", arguments: ["status": param.isEmpty ? "pending" : param])
        case "create_task":
            return ModelToolCall(toolName: "create_task", arguments: ["title": param])
        case "complete_task":
            return ModelToolCall(toolName: "complete_task", arguments: ["id": param])
        case "delete_task":
            return ModelToolCall(toolName: "delete_task", arguments: ["id": param])
        default:
            return ModelToolCall(toolName: action, arguments: ["param": param])
        }
    }
}
