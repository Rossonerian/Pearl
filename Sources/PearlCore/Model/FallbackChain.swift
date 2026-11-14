import Foundation

public struct ChainStepFailure: Sendable {
    public let step: String
    public let reason: String
    
    public init(step: String, reason: String) {
        self.step = step
        self.reason = reason
    }
}

public final class FallbackChain: Sendable {
    public let appleFM: AppleFMProvider
    public let mlxProvider: MLXProvider
    public let frontier: FrontierProvider
    public let pccEnabled: Bool
    public let mlxEnabled: Bool
    
    public init(
        appleFM: AppleFMProvider = AppleFMProvider(),
        mlxProvider: MLXProvider = .shared,
        frontier: FrontierProvider = FrontierProvider(),
        pccEnabled: Bool = PearlConfig.load().pccEnabled,
        mlxEnabled: Bool = PearlConfig.load().mlxEnabled
    ) {
        self.appleFM = appleFM
        self.mlxProvider = mlxProvider
        self.frontier = frontier
        self.pccEnabled = pccEnabled
        self.mlxEnabled = mlxEnabled
    }
    
    public func process(
        utterance: String,
        context: ModelExecutionContext = ModelExecutionContext()
    ) async -> ModelResponse {
        var failureLog: [ChainStepFailure] = []
        
        // 1. Step 1: On-device Apple Foundation Models
        if !context.forceEscalation {
            do {
                let response = try await appleFM.generate(prompt: utterance, context: context)
                return response
            } catch {
                failureLog.append(ChainStepFailure(
                    step: "On-device Apple FM",
                    reason: error.localizedDescription
                ))
            }
        } else {
            failureLog.append(ChainStepFailure(
                step: "On-device Apple FM",
                reason: "Bypassed: user or task requested frontier escalation."
            ))
        }
        
        // 1.5. Step 1.5: On-device Small MLX
        if mlxEnabled && !context.forceEscalation {
            do {
                let response = try await mlxProvider.generate(prompt: utterance, context: context)
                return response
            } catch {
                failureLog.append(ChainStepFailure(
                    step: "On-device Small MLX",
                    reason: error.localizedDescription
                ))
            }
        } else {
            failureLog.append(ChainStepFailure(
                step: "On-device Small MLX",
                reason: mlxEnabled ? "Bypassed: user or task requested frontier escalation." : "On-device Small MLX: Disabled in settings"
            ))
        }
        
        // 2. Step 2: Private Cloud Compute (PCC)
        if pccEnabled {
            // If PCC is enabled, in future versions it routes to Apple PCC infrastructure
            failureLog.append(ChainStepFailure(
                step: "Private Cloud Compute (PCC)",
                reason: "PCC route unavailable or developer ID credentials unverified."
            ))
        } else {
            failureLog.append(ChainStepFailure(
                step: "Private Cloud Compute (PCC)",
                reason: "Not configured or disabled in settings."
            ))
        }
        
        // 3. Step 3: BYO Frontier Model (Claude)
        do {
            let response = try await frontier.generate(prompt: utterance, context: context)
            return response
        } catch {
            failureLog.append(ChainStepFailure(
                step: "Frontier (Claude)",
                reason: error.localizedDescription
            ))
        }
        
        // 4. Step 4: Offline Canned Message (Zero Silent Failures)
        let explanation = generateExplicitExplanation(for: utterance, failures: failureLog)
        let badge = HUDTurnBadge(
            label: "offline fallback",
            provider: "Offline Fallback",
            modelID: "canned",
            isLocal: true,
            details: "all model tiers failed"
        )
        
        return ModelResponse(
            content: explanation,
            toolCalls: [],
            usage: nil,
            providerName: "Offline Fallback",
            modelID: "canned",
            isLocal: true,
            badge: badge
        )
    }
    
    private func generateExplicitExplanation(for utterance: String, failures: [ChainStepFailure]) -> String {
        var lines: [String] = []
        lines.append("I am currently offline or unable to reach AI models to process this request.")
        lines.append("")
        lines.append("Diagnostic summary of fallback chain:")
        for (idx, f) in failures.enumerated() {
            lines.append("  \(idx + 1). \(f.step): \(f.reason)")
        }
        lines.append("")
        lines.append("Available offline actions:")
        lines.append("Pearl can still run deterministic actions without any model:")
        lines.append("• Volume control (\"mute\", \"set volume to 50\")")
        lines.append("• Battery status (\"check battery\")")
        lines.append("• App management (\"open Safari\", \"close Spotify\")")
        lines.append("• Reminders (\"remind me to...\")")
        lines.append("• Tasks (\"list tasks\", \"create task buy milk\", \"complete task buy milk\")")
        lines.append("• Screenshots (\"take screenshot\", \"clean screenshots\")")
        lines.append("• Git status (\"git status\")")
        
        return lines.joined(separator: "\n")
    }
}
