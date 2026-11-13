import Foundation

public enum FrontierError: LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case networkUnavailable(String)
    case invalidResponse(String)
    case httpError(status: Int, message: String)
    case spendCapBlocked(String)
    
    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Anthropic API key is missing. Store your key in Keychain to use Frontier models."
        case .networkUnavailable(let reason):
            return "Frontier network unavailable: \(reason)"
        case .invalidResponse(let details):
            return "Frontier provider returned an invalid response: \(details)"
        case .httpError(let status, let msg):
            return "Frontier API error (HTTP \(status)): \(msg)"
        case .spendCapBlocked(let reason):
            return "Frontier call blocked by spend cap: \(reason)"
        }
    }
}

public final class FrontierProvider: ModelProvider, @unchecked Sendable {
    public let name = "Frontier (Claude)"
    public var modelID: String
    public let isLocal = false
    public let maxAllowedTier = ToolTier.t5RawShell
    
    public let fastModelID: String
    public let escalationModelID: String
    public let endpointURL: URL
    public let spendTracker: SpendCapTracker
    
    // Test hooks for verification benchmarks & simulation
    public var isSimulatedOffline: Bool = false
    public var simulatedErrorReason: String? = nil
    public var mockResponseHandler: ((String) throws -> ModelResponse)? = nil
    
    public init(
        config: PearlConfig = PearlConfig.load(),
        spendTracker: SpendCapTracker = .shared
    ) {
        self.fastModelID = config.fastModelID
        self.escalationModelID = config.escalationModelID
        self.modelID = config.fastModelID
        self.endpointURL = URL(string: config.modelProviderEndpoint) ?? URL(string: "https://api.anthropic.com/v1/messages")!
        self.spendTracker = spendTracker
    }
    
    public func generate(prompt: String, context: ModelExecutionContext = ModelExecutionContext()) async throws -> ModelResponse {
        // 1. Check simulated offline status
        if isSimulatedOffline {
            throw FrontierError.networkUnavailable(simulatedErrorReason ?? "Simulated offline / airplane mode")
        }
        
        // 2. Client-side spend cap check (enforced prior to any network or mock execution)
        do {
            try spendTracker.checkSpendCap()
            let requestedTokens = context.maxTokens ?? 4096
            try spendTracker.checkTurnTokenLimit(tokens: requestedTokens)
        } catch let spendError as SpendCapError {
            throw FrontierError.spendCapBlocked(spendError.localizedDescription)
        }
        
        // 3. Mock handler for isolated offline testing
        if let mock = mockResponseHandler {
            return try mock(prompt)
        }
        
        // 4. Select model (fast vs escalation)
        let activeModelID = context.forceEscalation ? escalationModelID : fastModelID
        
        // 5. Retrieve key safely from Keychain (model never sees this key)
        guard let apiKey = try loadAPIKey(), !apiKey.isEmpty else {
            throw FrontierError.missingAPIKey
        }
        
        // 6. Build request payload
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 15.0
        
        var payload: [String: Any] = [
            "model": activeModelID,
            "max_tokens": context.maxTokens ?? 1024,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        if let systemPrompt = context.systemPrompt {
            payload["system"] = systemPrompt
        }
        if let temp = context.temperature {
            payload["temperature"] = temp
        }
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else {
            throw FrontierError.invalidResponse("Failed to serialize request payload.")
        }
        request.httpBody = httpBody
        
        // 7. Perform network request
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FrontierError.networkUnavailable(error.localizedDescription)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FrontierError.invalidResponse("Non-HTTP response received.")
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            let redactedMsg = KeychainService.redact(text: errorMsg)
            throw FrontierError.httpError(status: httpResponse.statusCode, message: redactedMsg)
        }
        
        // 8. Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FrontierError.invalidResponse("Failed to parse JSON response.")
        }
        
        var responseText = ""
        if let contentBlocks = json["content"] as? [[String: Any]] {
            for block in contentBlocks {
                if let text = block["text"] as? String {
                    responseText += text
                }
            }
        }
        
        // Parse token usage and record spend
        var tokenUsage: TokenUsage? = nil
        var costSummary: String? = nil
        if let usageDict = json["usage"] as? [String: Any],
           let inputTokens = usageDict["input_tokens"] as? Int,
           let outputTokens = usageDict["output_tokens"] as? Int {
            tokenUsage = TokenUsage(promptTokens: inputTokens, completionTokens: outputTokens)
            let cost = spendTracker.recordUsage(modelID: activeModelID, inputTokens: inputTokens, outputTokens: outputTokens)
            costSummary = String(format: "%d tokens ($%.4f)", inputTokens + outputTokens, cost)
        }
        
        let badge = HUDTurnBadge(
            label: "sent to Claude (\(activeModelID))",
            provider: name,
            modelID: activeModelID,
            isLocal: false,
            details: costSummary
        )
        
        return ModelResponse(
            content: responseText,
            toolCalls: [],
            usage: tokenUsage,
            providerName: name,
            modelID: activeModelID,
            isLocal: false,
            badge: badge
        )
    }
    
    public func stream(prompt: String, context: ModelExecutionContext = ModelExecutionContext()) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // For streaming, if offline or mock, handle accordingly
                    if self.isSimulatedOffline {
                        throw FrontierError.networkUnavailable(self.simulatedErrorReason ?? "Simulated offline")
                    }
                    if let mock = self.mockResponseHandler {
                        let res = try mock(prompt)
                        continuation.yield(res.content)
                        continuation.finish()
                        return
                    }
                    
                    // Simple streaming delegation via full generation chunking
                    let response = try await self.generate(prompt: prompt, context: context)
                    continuation.yield(response.content)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    private func loadAPIKey() throws -> String? {
        // Try standard keys in order
        if let key = try KeychainService.shared.loadKey(account: "anthropic") {
            return key
        }
        if let key = try KeychainService.shared.loadKey(account: "anthropic_api_key") {
            return key
        }
        if let key = try KeychainService.shared.loadKey(account: "frontier_api_key") {
            return key
        }
        return nil
    }
}
