import Foundation

public struct ResolvedIntent: Sendable {
    public let toolName: String
    public let arguments: [String: String]
    public let confidence: Double
    
    public init(toolName: String, arguments: [String: String], confidence: Double) {
        self.toolName = toolName
        self.arguments = arguments
        self.confidence = confidence
    }
}

public enum RouterResult: Sendable {
    case deterministic(intent: ResolvedIntent, badge: HUDTurnBadge)
    case model(response: ModelResponse, badge: HUDTurnBadge)
    case cancelled(reason: String)
}

public final class DeterministicRouter: Sendable {
    public static let shared = DeterministicRouter()
    
    // Negation patterns: "don't", "do not", "never mind", "stop", "cancel"
    private let negationPatterns: [String] = [
        "don't", "dont", "do not", "never mind", "cancel that", "abort", "ignore that"
    ]
    
    public init() {}
    
    /// Routes utterance through deterministic matcher first; if low-confidence or open-ended,
    /// falls back to the provided FallbackChain.
    public func route(
        utterance: String,
        fallbackChain: FallbackChain = FallbackChain(),
        context: ModelExecutionContext = ModelExecutionContext()
    ) async -> RouterResult {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .cancelled(reason: "Empty utterance.")
        }
        let lower = trimmed.lowercased()
        
        // 1. Negation Guard: never execute on negated requests
        for neg in negationPatterns {
            if lower.hasPrefix(neg) || lower.contains(" " + neg + " ") {
                return .cancelled(reason: "Negation detected: user aborted or cancelled action.")
            }
        }
        
        // 2. High-confidence deterministic rule resolution
        if let intent = resolve(utterance: trimmed) {
            let badge = HUDTurnBadge(
                label: "on device",
                provider: "Deterministic",
                modelID: "regex",
                isLocal: true,
                details: String(format: "confidence: %.2f", intent.confidence)
            )
            return .deterministic(intent: intent, badge: badge)
        }
        
        // 3. Low-confidence fallback to FallbackChain
        let response = await fallbackChain.process(utterance: trimmed, context: context)
        return .model(response: response, badge: response.badge)
    }
    
    public func resolve(utterance: String) -> ResolvedIntent? {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        
        // 1. Negation Guard: never execute on negated requests
        for neg in negationPatterns {
            if lower.hasPrefix(neg) || lower.contains(" " + neg + " ") {
                return nil
            }
        }
        
        // 2. Undo Intent
        if lower == "undo" || lower == "undo that" || lower == "revert that" {
            return ResolvedIntent(toolName: "undo", arguments: [:], confidence: 1.0)
        }
        
        // 3. Battery Intent
        if lower.contains("battery") || lower.contains("power level") || lower.contains("charging") {
            return ResolvedIntent(toolName: "battery", arguments: [:], confidence: 1.0)
        }
        
        // 4. Volume Intent
        if lower.contains("mute") || lower == "silence" {
            return ResolvedIntent(toolName: "volume", arguments: ["level": "0"], confidence: 1.0)
        }
        if lower.contains("unmute") {
            return ResolvedIntent(toolName: "volume", arguments: ["level": "30"], confidence: 1.0)
        }
        if let vol = extractVolumeLevel(from: lower) {
            return ResolvedIntent(toolName: "volume", arguments: ["level": "\(vol)"], confidence: 1.0)
        }
        
        // 5. Screenshot Actions
        if lower.contains("clean") && (lower.contains("screenshot") || lower.contains("screenshots")) ||
           lower.contains("trash") && lower.contains("screenshot") ||
           lower.contains("delete") && lower.contains("screenshot") {
            return ResolvedIntent(toolName: "trash_screenshots", arguments: [:], confidence: 1.0)
        }
        if lower.contains("screenshot") || lower.contains("capture screen") || lower.contains("grab screen") {
            return ResolvedIntent(toolName: "screenshot", arguments: [:], confidence: 1.0)
        }
        
        // 6. Application Launch / Quit
        if lower.hasPrefix("open ") || lower.hasPrefix("launch ") {
            let appName = String(trimmed.dropFirst(trimmed.hasPrefix("launch ") ? 7 : 5)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "open_app", arguments: ["app": appName], confidence: 0.98)
        }
        if lower.hasPrefix("close ") || lower.hasPrefix("quit ") {
            let appName = String(trimmed.dropFirst(trimmed.hasPrefix("close ") ? 6 : 5)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "close_app", arguments: ["app": appName], confidence: 0.98)
        }
        
        // 7. Git Actions
        if lower.contains("git status") || lower.contains("git branch") || lower.contains("working tree") || lower.contains("repo status") {
            return ResolvedIntent(toolName: "git", arguments: ["subcommand": "status"], confidence: 1.0)
        }
        
        // 8. Reminders
        if lower.hasPrefix("remind me to ") {
            let text = String(trimmed.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "reminder", arguments: ["title": text], confidence: 0.95)
        }
        if lower.hasPrefix("create reminder ") || lower.hasPrefix("add reminder ") {
            let text = String(trimmed.dropFirst(16)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "reminder", arguments: ["title": text], confidence: 0.95)
        }
        
        return nil
    }
    
    private func extractVolumeLevel(from text: String) -> Int? {
        if !text.contains("volume") { return nil }
        let pattern = #"(?:volume\s+(?:to\s+)?|set\s+volume\s+)(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[range])
    }
    
    public func generateClosedVocabulary() -> [String] {
        return [
            "mute volume", "unmute", "volume", "battery", "is macbook charging",
            "take screenshot", "capture screen", "clean up screenshots",
            "open Safari", "open Code", "close Safari", "quit Code",
            "git status", "git branch", "undo", "undo that", "remind me to"
        ]
    }
}
