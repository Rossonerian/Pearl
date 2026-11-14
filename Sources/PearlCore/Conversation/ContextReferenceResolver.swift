import Foundation

/// Result of contextual reference resolution across conversation turns.
public struct ContextResolutionResult: Sendable, Equatable {
    public let originalUtterance: String
    public let resolvedUtterance: String
    public let didResolve: Bool
    public let resolvedIntent: ResolvedIntent?
    public let antecedentEntity: String?
    public let entityCategory: String?
    
    public init(
        originalUtterance: String,
        resolvedUtterance: String,
        didResolve: Bool,
        resolvedIntent: ResolvedIntent? = nil,
        antecedentEntity: String? = nil,
        entityCategory: String? = nil
    ) {
        self.originalUtterance = originalUtterance
        self.resolvedUtterance = resolvedUtterance
        self.didResolve = didResolve
        self.resolvedIntent = resolvedIntent
        self.antecedentEntity = antecedentEntity
        self.entityCategory = entityCategory
    }
}

/// Resolves pronoun, demonstrative, and contextual references across consecutive conversational turns.
///
/// Handles:
/// - Application anaphora: Turn 1: "open Safari" -> Turn 2: "now close it" -> resolves "it" to "Safari" (`close_app`).
/// - Repository anaphora: Turn 1: "check git status in Pearl" -> Turn 2: "what branch is that?" -> resolves "that" to "Pearl".
/// - Repeat / repetition anaphora: "do it again", "again", "the same thing" -> repeats previous intent.
public final class ContextReferenceResolver: Sendable {
    public init() {}
    
    /// Checks whether an utterance contains anaphoric pronouns or repetition markers.
    public func containsAnaphora(_ utterance: String) -> Bool {
        let lower = utterance.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\b(it|that|this|them|its|again|the same|same thing|repeat|once more|one more time|the app|that app|the application|that application|the repo|that repo|the repository|that repository|the branch|that branch)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return false
        }
        return regex.firstMatch(in: lower, range: NSRange(location: 0, length: lower.utf16.count)) != nil
    }
    
    /// Resolves contextual references in `utterance` against prior turns in `history`.
    public func resolve(utterance: String, history: [ConversationTurn]) -> ContextResolutionResult {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !history.isEmpty else {
            return ContextResolutionResult(
                originalUtterance: trimmed,
                resolvedUtterance: trimmed,
                didResolve: false
            )
        }
        
        let lower = trimmed.lowercased()
        
        // 1. Repetition / Replay Intent ("again", "do it again", "the same")
        if isRepetitionUtterance(lower), let lastTurn = history.last {
            if let intent = lastTurn.resolvedIntent {
                return ContextResolutionResult(
                    originalUtterance: trimmed,
                    resolvedUtterance: lastTurn.cleanedInput,
                    didResolve: true,
                    resolvedIntent: intent,
                    antecedentEntity: intent.toolName,
                    entityCategory: "tool"
                )
            } else if let firstTool = lastTurn.toolInvocations.first {
                let intent = ResolvedIntent(toolName: firstTool.toolName, arguments: firstTool.arguments, confidence: 0.98)
                return ContextResolutionResult(
                    originalUtterance: trimmed,
                    resolvedUtterance: lastTurn.cleanedInput,
                    didResolve: true,
                    resolvedIntent: intent,
                    antecedentEntity: firstTool.toolName,
                    entityCategory: "tool"
                )
            } else {
                return ContextResolutionResult(
                    originalUtterance: trimmed,
                    resolvedUtterance: lastTurn.cleanedInput,
                    didResolve: true,
                    resolvedIntent: nil,
                    antecedentEntity: nil,
                    entityCategory: "utterance"
                )
            }
        }
        
        // 2. Application Anaphora Resolution ("now close it", "open it", "quit that")
        if let appAction = detectApplicationAction(in: lower) {
            if let appName = extractMostRecentAppEntity(from: history) {
                switch appAction {
                case .close:
                    let rewritten = "close \(appName)"
                    let intent = ResolvedIntent(toolName: "close_app", arguments: ["app": appName], confidence: 0.98)
                    return ContextResolutionResult(
                        originalUtterance: trimmed,
                        resolvedUtterance: rewritten,
                        didResolve: true,
                        resolvedIntent: intent,
                        antecedentEntity: appName,
                        entityCategory: "application"
                    )
                case .open:
                    let rewritten = "open \(appName)"
                    let intent = ResolvedIntent(toolName: "open_app", arguments: ["app": appName], confidence: 0.98)
                    return ContextResolutionResult(
                        originalUtterance: trimmed,
                        resolvedUtterance: rewritten,
                        didResolve: true,
                        resolvedIntent: intent,
                        antecedentEntity: appName,
                        entityCategory: "application"
                    )
                }
            }
        }
        
        // 3. Repository / Git Anaphora Resolution ("what branch is that?", "status of that")
        if isGitOrBranchQuery(lower) {
            if let repo = extractMostRecentRepoEntity(from: history) {
                let args = ["subcommand": "status", "repo": repo]
                let rewritten = "git branch in \(repo)"
                let intent = ResolvedIntent(toolName: "git", arguments: args, confidence: 0.98)
                return ContextResolutionResult(
                    originalUtterance: trimmed,
                    resolvedUtterance: rewritten,
                    didResolve: true,
                    resolvedIntent: intent,
                    antecedentEntity: repo,
                    entityCategory: "repository"
                )
            }
        }
        
        // 4. General Pronoun Replacement Heuristic
        if let appName = extractMostRecentAppEntity(from: history), lower.contains("the app") || lower.contains("that app") {
            let replaced = replacePhrase(in: trimmed, phrase: "the app", with: appName)
            let replacedFinal = replacePhrase(in: replaced, phrase: "that app", with: appName)
            return ContextResolutionResult(
                originalUtterance: trimmed,
                resolvedUtterance: replacedFinal,
                didResolve: true,
                antecedentEntity: appName,
                entityCategory: "application"
            )
        }
        
        if let repo = extractMostRecentRepoEntity(from: history), lower.contains("the repo") || lower.contains("that repo") {
            let replaced = replacePhrase(in: trimmed, phrase: "the repo", with: repo)
            let replacedFinal = replacePhrase(in: replaced, phrase: "that repo", with: repo)
            return ContextResolutionResult(
                originalUtterance: trimmed,
                resolvedUtterance: replacedFinal,
                didResolve: true,
                antecedentEntity: repo,
                entityCategory: "repository"
            )
        }
        
        return ContextResolutionResult(
            originalUtterance: trimmed,
            resolvedUtterance: trimmed,
            didResolve: false
        )
    }
    
    // MARK: - Helper Classifiers
    
    private enum AppActionVerb {
        case open
        case close
    }
    
    private func detectApplicationAction(in lower: String) -> AppActionVerb? {
        let isClose = lower.contains("close") || lower.contains("quit") || lower.contains("kill") || lower.contains("shut down")
        let isOpen = lower.contains("open") || lower.contains("launch") || lower.contains("activate") || lower.contains("bring up")
        
        let hasAppPronoun = lower.contains(" it") || lower.hasSuffix(" it") ||
                            lower.contains(" that") || lower.hasSuffix(" that") ||
                            lower.contains(" the app") || lower.contains(" that app") ||
                            lower.contains(" the application") || lower.contains(" that application")
        
        guard hasAppPronoun else { return nil }
        
        if isClose && !isOpen {
            return .close
        } else if isOpen && !isClose {
            return .open
        }
        return nil
    }
    
    private func isGitOrBranchQuery(_ lower: String) -> Bool {
        let branchPhrases = ["what branch", "which branch", "current branch", "git status", "status of that", "status of it", "is that clean", "is it clean"]
        for phrase in branchPhrases {
            if lower.contains(phrase) {
                return true
            }
        }
        return false
    }
    
    private func isRepetitionUtterance(_ lower: String) -> Bool {
        let exactPhrases: Set<String> = [
            "again", "do it again", "do that again", "the same", "the same thing",
            "same thing", "repeat", "repeat that", "once more", "one more time", "retry"
        ]
        if exactPhrases.contains(lower) {
            return true
        }
        if lower.hasPrefix("please ") {
            let stripped = String(lower.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            return exactPhrases.contains(stripped)
        }
        return false
    }
    
    // MARK: - Entity Extraction
    
    /// Extracts the most recent application name referenced in recent turns.
    public func extractMostRecentAppEntity(from history: [ConversationTurn]) -> String? {
        for turn in history.reversed() {
            // Check tool invocations
            for inv in turn.toolInvocations.reversed() {
                if inv.toolName == "open_app" || inv.toolName == "close_app" {
                    if let app = inv.arguments["app"], !app.isEmpty {
                        return app
                    }
                }
            }
            
            // Check resolved intent
            if let intent = turn.resolvedIntent, (intent.toolName == "open_app" || intent.toolName == "close_app") {
                if let app = intent.arguments["app"], !app.isEmpty {
                    return app
                }
            }
            
            // Extract from input text e.g. "open Safari", "launch Xcode"
            let text = turn.cleanedInput
            let pattern = #"(?:open|launch|start|close|quit|activate)\s+([A-Z][a-zA-Z0-9_\s]{1,30})"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
               let range = Range(match.range(at: 1), in: text) {
                let candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty && !candidate.lowercased().contains("it") && !candidate.lowercased().contains("that") {
                    return candidate
                }
            }
        }
        return nil
    }
    
    /// Extracts the most recent repository or project name referenced in recent turns.
    public func extractMostRecentRepoEntity(from history: [ConversationTurn]) -> String? {
        for turn in history.reversed() {
            // Check tool invocations
            for inv in turn.toolInvocations.reversed() {
                if inv.toolName == "git" || inv.toolName == "git_status" {
                    if let repo = inv.arguments["repo"] ?? inv.arguments["path"], !repo.isEmpty {
                        return repo
                    }
                }
            }
            
            // Check resolved intent
            if let intent = turn.resolvedIntent, intent.toolName == "git" {
                if let repo = intent.arguments["repo"] ?? intent.arguments["path"], !repo.isEmpty {
                    return repo
                }
            }
            
            // Extract from input text e.g. "check git status in Pearl"
            let text = turn.cleanedInput
            let pattern = #"(?:git\s+status|git\s+branch|status)\s+(?:in|for|of)\s+([A-Za-z0-9_\-\.\/]+)"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
               let range = Range(match.range(at: 1), in: text) {
                let candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty && !candidate.lowercased().contains("that") && !candidate.lowercased().contains("it") {
                    return candidate
                }
            }
        }
        return nil
    }
    
    private func replacePhrase(in text: String, phrase: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"\b"#, options: .caseInsensitive) else {
            return text
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
