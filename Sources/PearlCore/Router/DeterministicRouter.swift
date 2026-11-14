import Foundation

public struct ResolvedIntent: Sendable, Codable, Equatable {
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
        let rawLower = trimmed.lowercased()
        
        // 1. Negation Guard: never execute on negated requests
        for neg in negationPatterns {
            if rawLower.hasPrefix(neg) || rawLower.contains(" " + neg + " ") {
                return nil
            }
        }
        
        // Clean wake words and politeness prefixes/suffixes
        let cleaned = cleanUtterance(trimmed)
        guard !cleaned.isEmpty else { return nil }
        let lower = cleaned.lowercased()
        
        // 2. Undo Intent
        if lower == "undo" || lower == "undo that" || lower == "revert that" {
            return ResolvedIntent(toolName: "undo", arguments: [:], confidence: 1.0)
        }
        
        // 3. Battery Intent
        if lower.contains("battery") || lower.contains("power level") || lower.contains("charging") || lower.contains("plugged into power") {
            return ResolvedIntent(toolName: "battery", arguments: [:], confidence: 1.0)
        }
        
        // 4. Volume Intent
        if lower.contains("unmute") {
            return ResolvedIntent(toolName: "volume", arguments: ["level": "30"], confidence: 1.0)
        }
        if lower.contains("mute") || lower == "silence" || lower.contains("turn sound off") || lower.contains("sound off") {
            return ResolvedIntent(toolName: "volume", arguments: ["level": "0"], confidence: 1.0)
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
        if lower.contains("screenshot") || lower.contains("capture screen") || lower.contains("capture display") || lower.contains("capture my screen") || lower.contains("grab screen") {
            return ResolvedIntent(toolName: "screenshot", arguments: [:], confidence: 1.0)
        }
        
        // 6. Application Launch / Quit
        if lower.hasPrefix("open ") || lower.hasPrefix("launch ") {
            let appName = String(cleaned.dropFirst(cleaned.hasPrefix("launch ") ? 7 : 5)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "open_app", arguments: ["app": appName], confidence: 0.98)
        }
        if lower.hasPrefix("close ") || lower.hasPrefix("quit ") {
            let appName = String(cleaned.dropFirst(cleaned.hasPrefix("close ") ? 6 : 5)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "close_app", arguments: ["app": appName], confidence: 0.98)
        }
        
        // 7. Git Actions (status observation)
        if lower.contains("git status") || lower.contains("git branch") || lower.contains("working tree") || lower.contains("repo status") {
            return ResolvedIntent(toolName: "git", arguments: ["subcommand": "status"], confidence: 1.0)
        }
        
        // 8. Reminders
        if lower.hasPrefix("remind me to ") {
            let text = String(cleaned.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "reminder", arguments: ["title": text], confidence: 0.95)
        }
        if lower.hasPrefix("create reminder ") {
            let text = String(cleaned.dropFirst(16)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "reminder", arguments: ["title": text], confidence: 0.95)
        }
        if lower.hasPrefix("add reminder ") {
            let text = String(cleaned.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "reminder", arguments: ["title": text], confidence: 0.95)
        }
        
        // 9. Tasks & To-Dos
        if lower == "list tasks" || lower == "my tasks" || lower == "show tasks" || lower == "show my tasks" || lower == "task list" || lower == "what are my tasks" {
            return ResolvedIntent(toolName: "list_tasks", arguments: ["status": "pending"], confidence: 1.0)
        }
        if lower.hasPrefix("create task ") || lower.hasPrefix("add task ") || lower.hasPrefix("new task ") {
            let prefixCount = lower.hasPrefix("create task ") ? 12 : (lower.hasPrefix("add task ") ? 9 : 9)
            let title = String(cleaned.dropFirst(prefixCount)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "create_task", arguments: ["title": title], confidence: 0.98)
        }
        if lower.hasPrefix("complete task ") || lower.hasPrefix("finish task ") {
            let prefixCount = lower.hasPrefix("complete task ") ? 14 : 12
            let id = String(cleaned.dropFirst(prefixCount)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "complete_task", arguments: ["id": id], confidence: 0.98)
        }
        if lower.hasPrefix("delete task ") {
            let id = String(cleaned.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "delete_task", arguments: ["id": id], confidence: 0.98)
        }
        
        // 10. Window Observation
        if lower == "list windows" || lower == "show open windows" {
            return ResolvedIntent(toolName: "list_windows", arguments: [:], confidence: 1.0)
        }
        
        // 11. Screen Reading (OCR)
        if lower == "what is on my screen" || lower == "what's on my screen" || lower == "read my screen" {
            return ResolvedIntent(toolName: "read_screen_text", arguments: [:], confidence: 1.0)
        }
        
        // 12. Shortcuts
        if lower == "list shortcuts" || lower == "show shortcuts" {
            return ResolvedIntent(toolName: "list_shortcuts", arguments: [:], confidence: 1.0)
        }
        
        // 13. Browser Tabs
        if lower == "list browser tabs" || lower == "show browser tabs" || lower == "what tabs are open" {
            return ResolvedIntent(toolName: "list_browser_tabs", arguments: [:], confidence: 1.0)
        }
        
        // 14. Calendar & Clipboard (for Skills & Direct Commands)
        if lower == "list calendar events" || lower == "show calendar events" || lower == "my calendar events" || lower == "check calendar" {
            return ResolvedIntent(toolName: "list_calendar_events", arguments: ["time_window": "today"], confidence: 1.0)
        }
        if lower == "read clipboard" || lower == "check clipboard" || lower == "what is in my clipboard" || lower == "what's in my clipboard" {
            return ResolvedIntent(toolName: "read_clipboard", arguments: [:], confidence: 1.0)
        }
        
        // 15. V3.2 Vault, Persona, Dream & Cache Shortcuts (exact-match, post-negation guard)
        if lower == "list vault notes" || lower == "show vault notes" {
            return ResolvedIntent(toolName: "vault_list", arguments: [:], confidence: 1.0)
        }
        if lower == "switch to ultron mode" || lower == "ultron mode" {
            return ResolvedIntent(toolName: "set_persona", arguments: ["mode": "ultron"], confidence: 1.0)
        }
        if lower == "switch to executive mode" || lower == "executive mode" {
            return ResolvedIntent(toolName: "set_persona", arguments: ["mode": "executive"], confidence: 1.0)
        }
        if lower == "switch to jarvis mode" || lower == "jarvis mode" {
            return ResolvedIntent(toolName: "set_persona", arguments: ["mode": "jarvis"], confidence: 1.0)
        }
        if lower == "dream" || lower == "run dream" || lower == "synthesize memories" {
            return ResolvedIntent(toolName: "dream_synthesis", arguments: [:], confidence: 1.0)
        }
        if lower == "cache stats" || lower == "show cache stats" {
            return ResolvedIntent(toolName: "cache_stats", arguments: [:], confidence: 1.0)
        }
        
        return nil
    }
    
    func cleanUtterance(_ utterance: String) -> String {
        var text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "hey pearl, ", "hey pearl ", "pearl, ", "pearl ",
            "please, ", "please ",
            "could you please ", "could you ",
            "can you please ", "can you "
        ]
        var changed = true
        while changed {
            changed = false
            for p in prefixes {
                if text.lowercased().hasPrefix(p) {
                    text = String(text.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
        }
        let suffixes = [", please", " please"]
        var changedSuffix = true
        while changedSuffix {
            changedSuffix = false
            for s in suffixes {
                if text.lowercased().hasSuffix(s) {
                    text = String(text.dropLast(s.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    changedSuffix = true
                }
            }
        }
        return text
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
            "git status", "git branch", "undo", "undo that", "remind me to",
            "list windows", "show open windows", "what's on my screen", "read my screen",
            "list shortcuts", "list browser tabs"
        ]
    }
}
