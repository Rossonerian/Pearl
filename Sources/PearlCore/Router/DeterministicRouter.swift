import Foundation

public struct ResolvedPlanStep: Sendable, Codable, Equatable {
    public let toolName: String
    public let arguments: [String: String]
    public let description: String
    
    public init(toolName: String, arguments: [String: String], description: String = "") {
        self.toolName = toolName
        self.arguments = arguments
        self.description = description
    }
}

public struct ResolvedIntent: Sendable, Codable, Equatable {
    public let toolName: String
    public let arguments: [String: String]
    public let confidence: Double
    public let planSteps: [ResolvedPlanStep]?
    public let clarificationPrompt: String?
    
    public init(
        toolName: String,
        arguments: [String: String],
        confidence: Double,
        planSteps: [ResolvedPlanStep]? = nil,
        clarificationPrompt: String? = nil
    ) {
        self.toolName = toolName
        self.arguments = arguments
        self.confidence = confidence
        self.planSteps = planSteps
        self.clarificationPrompt = clarificationPrompt
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
                label: "",
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
        if rawLower == "cancel" || rawLower == "no" || rawLower == "nope" {
            return nil
        }
        for neg in negationPatterns {
            if rawLower == neg || rawLower.hasPrefix(neg + " ") || rawLower.hasSuffix(" " + neg) || rawLower.contains(" " + neg + " ") {
                return nil
            }
        }
        
        // Clean wake words and politeness prefixes/suffixes
        let cleaned = cleanUtterance(trimmed)
        guard !cleaned.isEmpty else { return nil }
        let normalizedCleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        guard !normalizedCleaned.isEmpty else { return nil }
        let lower = normalizedCleaned.lowercased()
        let lowerNoQuestion = lower.trimmingCharacters(in: CharacterSet(charactersIn: "?")).trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Guard against meta/explanatory questions masquerading as imperative actions
        let isExplanatoryQuestion = (
            lower.hasPrefix("how do i ") ||
            lower.hasPrefix("how to ") ||
            lower.hasPrefix("what does ") ||
            lower.hasPrefix("what is the ") ||
            lower.hasPrefix("why ") ||
            lower.hasPrefix("explain ") ||
            lower.hasPrefix("can you explain ") ||
            lower.hasPrefix("should i ")
        )
        
        // 2. Undo Intent
        if lowerNoQuestion == "undo" || lowerNoQuestion == "undo that" || lowerNoQuestion == "revert that" ||
           lowerNoQuestion == "undo last" || lowerNoQuestion == "undo last operation" ||
           lowerNoQuestion == "undo the last operation" || lowerNoQuestion == "undo last folder operation" ||
           lowerNoQuestion == "undo the last folder operation" || lowerNoQuestion == "undo last file operation" ||
           lowerNoQuestion == "undo the last action" || lowerNoQuestion == "undo last action" {
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
        if lowerNoQuestion == "list reminders" || lowerNoQuestion == "list my reminders" || lowerNoQuestion == "show reminders" || lowerNoQuestion == "show my reminders" || lowerNoQuestion == "my reminders" {
            return ResolvedIntent(toolName: "reminder", arguments: ["action": "list"], confidence: 1.0)
        }
        if lowerNoQuestion.hasPrefix("complete reminder ") || lowerNoQuestion.hasPrefix("finish reminder ") || lowerNoQuestion.hasPrefix("mark reminder ") {
            var rem = String(normalizedCleaned.dropFirst(lowerNoQuestion.hasPrefix("complete reminder ") ? 18 : (lowerNoQuestion.hasPrefix("finish reminder ") ? 16 : 14)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if rem.lowercased().hasSuffix(" as done") { rem = String(rem.dropLast(8)) }
            else if rem.lowercased().hasSuffix(" done") { rem = String(rem.dropLast(5)) }
            else if rem.lowercased().hasSuffix(" complete") { rem = String(rem.dropLast(9)) }
            rem = rem.trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
            if !rem.isEmpty {
                return ResolvedIntent(toolName: "reminder", arguments: ["action": "complete", "title": rem], confidence: 0.96)
            }
        }
        if lower.hasPrefix("remind me to ") {
            let text = String(normalizedCleaned.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "reminder", arguments: ["action": "create", "title": text], confidence: 0.95)
        }
        if lower.hasPrefix("create reminder ") {
            let text = String(normalizedCleaned.dropFirst(16)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "reminder", arguments: ["action": "create", "title": text], confidence: 0.95)
        }
        if lower.hasPrefix("add reminder ") {
            let text = String(normalizedCleaned.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            return ResolvedIntent(toolName: "reminder", arguments: ["action": "create", "title": text], confidence: 0.95)
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
        
        // 15. V3.3 Filesystem Natural Language Grammar (guarded against explanatory questions)
        if !isExplanatoryQuestion {
            if let fsIntent = resolveFilesystemIntent(cleaned: normalizedCleaned, lower: lowerNoQuestion) {
                return fsIntent
            }
        }
        
        // 16. V3.2 Vault, Persona, Dream & Cache Shortcuts (exact-match, post-negation guard)
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
    
    // MARK: - Filesystem Grammar & Destination Resolution
    
    /// Resolves common macOS approved folder phrases or explicit paths into canonical paths without guessing.
    public func resolveKnownDirectory(from rawPhrase: String) -> String? {
        var phrase = rawPhrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.?!"))
        guard !phrase.isEmpty else { return nil }
        
        // Strip leading conversational prepositions / possessives
        let leadingTokens = ["on my ", "in my ", "inside my ", "into my ", "under my ", "at my ",
                             "on the ", "in the ", "inside the ", "into the ", "under the ", "at the ",
                             "my ", "the ", "on ", "in ", "inside ", "into ", "under ", "at ", "to ", "from "]
        var trimmedLoop = true
        while trimmedLoop {
            trimmedLoop = false
            let pLower = phrase.lowercased()
            for tok in leadingTokens {
                if pLower.hasPrefix(tok) {
                    phrase = String(phrase.dropFirst(tok.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    trimmedLoop = true
                    break
                }
            }
        }
        
        let trailingTokens = [" folder", " directory"]
        for tok in trailingTokens {
            if phrase.lowercased().hasSuffix(tok) && phrase.count > tok.count {
                phrase = String(phrase.dropLast(tok.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !phrase.isEmpty else { return nil }
        
        if phrase.hasPrefix("~/") || phrase == "~" || phrase.hasPrefix("/") {
            return phrase
        }
        
        let low = phrase.lowercased()
        let rootMappings: [(prefix: String, canonical: String)] = [
            ("desktop", "~/Desktop"),
            ("documents", "~/Documents"),
            ("document", "~/Documents"),
            ("docs", "~/Documents"),
            ("downloads", "~/Downloads"),
            ("download", "~/Downloads"),
            ("projects", "~/Projects"),
            ("project", "~/Projects")
        ]
        for (key, canonical) in rootMappings {
            if low == key {
                return canonical
            }
            if low.hasPrefix(key + "/") {
                let rest = String(phrase.dropFirst(key.count + 1))
                return (canonical as NSString).appendingPathComponent(rest)
            }
        }
        return nil
    }
    
    private func resolveFilesystemIntent(cleaned: String, lower: String) -> ResolvedIntent? {
        // 1. Search Files: "Find all PDF files in Downloads", "Search for report in Documents"
        let searchExtPattern = #"^(?:find|search(?:\s+for)?)\s+(?:all\s+)?\.?([a-zA-Z0-9]{1,10})\s+files?\s+(?:in|on|inside|under)\s+(.+)$"#
        if let m = firstMatchGroups(pattern: searchExtPattern, in: cleaned), m.count >= 2 {
            let ext = m[0].trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
            let folderRaw = m[1]
            if let folder = resolveKnownDirectory(from: folderRaw) {
                return ResolvedIntent(
                    toolName: "search_files",
                    arguments: ["query": "", "extension": ext, "folder": folder],
                    confidence: 0.96
                )
            }
        }
        
        let searchNamePattern = #"^(?:find|search(?:\s+for)?)\s+(?:files?\s+(?:named|called|matching)\s+)?["']?(.+?)["']?\s+(?:in|on|inside|under)\s+(.+)$"#
        if (lower.hasPrefix("find ") || lower.hasPrefix("search ")),
           let m = firstMatchGroups(pattern: searchNamePattern, in: cleaned), m.count >= 2,
           let folder = resolveKnownDirectory(from: m[1]) {
            let query = m[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
            if !query.isEmpty {
                return ResolvedIntent(
                    toolName: "search_files",
                    arguments: ["query": query, "folder": folder],
                    confidence: 0.95
                )
            }
        }
        
        // 2. List Directory: "List the folders on my Desktop", "Show files in Downloads"
        let listPattern = #"^(?:list|show|what(?:'s| are)(?:\s+the)?)\s+(?:the\s+)?(?:all\s+)?(?:(folders?|directories|files?|contents?|items)\s+)?(?:on|in|inside|at|of|under)\s+(.+)$"#
        if let m = firstMatchGroups(pattern: listPattern, in: cleaned) {
            let kindToken = m.count > 0 ? m[0].lowercased() : ""
            let locRaw = m.last ?? ""
            if let dirPath = resolveKnownDirectory(from: locRaw) {
                var filterVal = "all"
                if kindToken.hasPrefix("folder") || kindToken.hasPrefix("direct") {
                    filterVal = "folders"
                } else if kindToken.hasPrefix("file") {
                    filterVal = "files"
                }
                return ResolvedIntent(
                    toolName: "list_directory",
                    arguments: ["path": dirPath, "filter": filterVal],
                    confidence: 0.98
                )
            }
        }
        if lower.hasPrefix("list directory ") || lower.hasPrefix("list folder ") || lower.hasPrefix("ls ") {
            let raw = lower.hasPrefix("ls ")
                ? String(cleaned.dropFirst(3))
                : String(cleaned.dropFirst(lower.hasPrefix("list directory ") ? 15 : 12))
            if let dirPath = resolveKnownDirectory(from: raw) {
                return ResolvedIntent(toolName: "list_directory", arguments: ["path": dirPath], confidence: 0.98)
            }
        }
        
        // 3. Create Folder(s):
        //    - "Create a folder called Pearl."
        //    - "Create Research on my Desktop."
        //    - "Make a folder named Experiments inside Documents."
        //    - "Create three folders named Backend, Frontend and Documentation."
        let createFolderKeywordPattern = #"^(?:create|make|new)\s+(?:a\s+|an\s+|two\s+|three\s+|four\s+|five\s+|six\s+|\d+\s+)?(?:new\s+)?(folders?|directories|directory)(?:\s+(?:called|named))?\s+(.+)$"#
        let skipShorthand = lower.hasPrefix("create task") || lower.hasPrefix("create a task") ||
                            lower.hasPrefix("create reminder") || lower.hasPrefix("create a reminder") ||
                            lower.hasPrefix("create calendar") || lower.hasPrefix("create event") ||
                            lower.hasPrefix("create mail") || lower.hasPrefix("make task")
        let createShorthandPattern = #"^(?:create|make)\s+(.+?)\s+(?:on|in|inside|at|under)\s+((?:my\s+|the\s+)?(?:Desktop|Documents|Downloads|Projects)(?:/\S+)?(?:\s+folder)?|~/\S+|/\S+)$"#
        
        if let m = firstMatchGroups(pattern: createFolderKeywordPattern, in: cleaned), m.count >= 2 {
            let keyword = m[0].lowercased()
            let remainder = m[1]
            let isPlural = keyword == "folders" || keyword == "directories" ||
                           lower.contains("two folders") || lower.contains("three folders") ||
                           lower.contains("four folders") || lower.contains("five folders")
            return buildCreateFolderIntent(remainder: remainder, isPluralHint: isPlural)
        }
        if !skipShorthand, let m = firstMatchGroups(pattern: createShorthandPattern, in: cleaned), m.count >= 2 {
            let rawName = m[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
            if let dest = resolveKnownDirectory(from: m[1]), !rawName.isEmpty {
                return buildResolvedCreateIntent(names: [rawName], destinationRoot: dest)
            }
        }
        
        // 4. Rename File or Folder: "Rename Research to Archive", "Rename Research on Desktop to Archive"
        let renamePattern = #"^rename\s+(?:the\s+)?(?:(?:file|folder|directory)\s+)?(.+?)\s+to\s+(.+)$"#
        if let m = firstMatchGroups(pattern: renamePattern, in: cleaned), m.count >= 2 {
            let sourceRaw = m[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
            let targetRaw = m[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
            guard !sourceRaw.isEmpty && !targetRaw.isEmpty else { return nil }
            
            var resolvedSource = sourceRaw
            if let locSplit = splitTrailingLocation(from: sourceRaw), let dir = resolveKnownDirectory(from: locSplit.location) {
                resolvedSource = (dir as NSString).appendingPathComponent(locSplit.item)
            }
            
            let resolvedDest: String
            if targetRaw.hasPrefix("/") || targetRaw.hasPrefix("~/") {
                resolvedDest = targetRaw
            } else if resolvedSource.contains("/") {
                let parent = (resolvedSource as NSString).deletingLastPathComponent
                resolvedDest = (parent as NSString).appendingPathComponent(targetRaw)
            } else {
                resolvedDest = targetRaw
            }
            return ResolvedIntent(
                toolName: "rename_file",
                arguments: ["source": resolvedSource, "destination": resolvedDest],
                confidence: 0.96
            )
        }
        
        // 5. Move File or Folder: "Move <src> [from <loc>] (?:to|into) <dest>"
        let movePattern = #"^move\s+(?:the\s+)?(?:(?:file|folder|directory)\s+)?(.+?)\s+(?:to|into)\s+(.+)$"#
        if lower.hasPrefix("move ") && !lower.contains(" to trash"),
           let m = firstMatchGroups(pattern: movePattern, in: cleaned), m.count >= 2 {
            let rawSource = m[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
            let rawDest = m[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
            guard !rawSource.isEmpty && !rawDest.isEmpty else { return nil }
            
            var resolvedSource = rawSource
            if let fromRange = rawSource.range(of: #"\s+(?:from|in|on|inside)\s+"#, options: [.regularExpression, .caseInsensitive]) {
                let item = String(rawSource[..<fromRange.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
                let loc = String(rawSource[fromRange.upperBound...])
                if let dir = resolveKnownDirectory(from: loc) {
                    resolvedSource = (dir as NSString).appendingPathComponent(item)
                }
            }
            let resolvedDest = resolveKnownDirectory(from: rawDest) ?? rawDest
            return ResolvedIntent(
                toolName: "move_file",
                arguments: ["source": resolvedSource, "destination": resolvedDest],
                confidence: 0.95
            )
        }
        
        // 6. Copy File: "Copy <src> [from <loc>] (?:to|into) <dest>"
        let copyPattern = #"^copy\s+(?:the\s+)?(?:file\s+)?(.+?)\s+(?:to|into)\s+(.+)$"#
        if let m = firstMatchGroups(pattern: copyPattern, in: cleaned), m.count >= 2 {
            let rawSource = m[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
            let rawDest = m[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
            var resolvedSource = rawSource
            if let fromRange = rawSource.range(of: #"\s+(?:from|in|on|inside)\s+"#, options: [.regularExpression, .caseInsensitive]) {
                let item = String(rawSource[..<fromRange.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
                let loc = String(rawSource[fromRange.upperBound...])
                if let dir = resolveKnownDirectory(from: loc) {
                    resolvedSource = (dir as NSString).appendingPathComponent(item)
                }
            }
            let resolvedDest = resolveKnownDirectory(from: rawDest) ?? rawDest
            return ResolvedIntent(
                toolName: "copy_file",
                arguments: ["source": resolvedSource, "destination": resolvedDest],
                confidence: 0.95
            )
        }
        
        // 7. Trash File / Folder: "Trash <path>", "Move <path> to trash", "Delete folder <path>"
        if !lower.contains("screenshot") && !lower.contains("task") {
            let trashToPattern = #"^move\s+(?:the\s+)?(?:(?:file|folder|directory)\s+)?(.+?)\s+to\s+(?:the\s+)?trash$"#
            let trashDirectPattern = #"^(?:trash|(?:delete|remove)\s+(?:the\s+)?(?:file|folder|directory))\s+(.+)$"#
            if let m = firstMatchGroups(pattern: trashToPattern, in: cleaned), let targetRaw = m.first {
                let target = resolveTargetWithOptionalLocation(targetRaw)
                return ResolvedIntent(toolName: "trash_file", arguments: ["path": target], confidence: 0.95)
            }
            if let m = firstMatchGroups(pattern: trashDirectPattern, in: cleaned), let targetRaw = m.first {
                let target = resolveTargetWithOptionalLocation(targetRaw)
                return ResolvedIntent(toolName: "trash_file", arguments: ["path": target], confidence: 0.95)
            }
        }
        
        // 8. Read File Safely: "Read file <path>"
        let readFilePattern = #"^(?:read|open|show contents of)\s+(?:the\s+)?file\s+(.+)$"#
        if let m = firstMatchGroups(pattern: readFilePattern, in: cleaned), let rawTarget = m.first {
            let target = resolveTargetWithOptionalLocation(rawTarget)
            return ResolvedIntent(toolName: "read_file_safe", arguments: ["path": target], confidence: 0.95)
        }
        
        return nil
    }
    
    private func buildCreateFolderIntent(remainder: String, isPluralHint: Bool) -> ResolvedIntent? {
        var namesPart = remainder.trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
        var destinationRoot: String? = nil
        
        if let split = splitTrailingLocation(from: namesPart),
           let resolvedDest = resolveKnownDirectory(from: split.location) {
            namesPart = split.item
            destinationRoot = resolvedDest
        }
        
        // Strip leading "called"/"named" if revealed after destination stripping
        for prefix in ["called ", "named "] {
            if namesPart.lowercased().hasPrefix(prefix) {
                namesPart = String(namesPart.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        let shouldSplitMultiple = isPluralHint || namesPart.contains(",") || namesPart.range(of: #"\s+and\s+"#, options: .caseInsensitive) != nil
        let names: [String]
        if shouldSplitMultiple {
            names = splitFolderNames(namesPart)
        } else {
            let cleanedSingle = namesPart.trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
            names = cleanedSingle.isEmpty ? [] : [cleanedSingle]
        }
        guard !names.isEmpty else { return nil }
        
        // If single explicit full path (e.g. "~/Desktop/Pearl" or "/tmp/foo"), execute directly without clarifying
        if names.count == 1, destinationRoot == nil, (names[0].hasPrefix("~/") || names[0].hasPrefix("/")) {
            return ResolvedIntent(
                toolName: "create_directory",
                arguments: ["path": names[0], "recursive": "false", "create_if_missing": "false"],
                confidence: 0.99
            )
        }
        
        guard let dest = destinationRoot else {
            let prompt: String
            if names.count > 1 {
                prompt = "Where should I create these folders (\(names.joined(separator: ", "))): Desktop, Documents, Downloads or Projects?"
            } else {
                prompt = "Where should I create it: Desktop, Documents, Downloads or Projects?"
            }
            return ResolvedIntent(
                toolName: "clarify_destination",
                arguments: [
                    "kind": names.count > 1 ? "create_directories" : "create_directory",
                    "names": names.joined(separator: "\n"),
                    "prompt": prompt
                ],
                confidence: 0.99,
                clarificationPrompt: prompt
            )
        }
        
        return buildResolvedCreateIntent(names: names, destinationRoot: dest)
    }
    
    private func buildResolvedCreateIntent(names: [String], destinationRoot: String) -> ResolvedIntent {
        let paths = names.map { name -> String in
            if name.hasPrefix("~/") || name.hasPrefix("/") { return name }
            return (destinationRoot as NSString).appendingPathComponent(name)
        }
        if paths.count == 1 {
            return ResolvedIntent(
                toolName: "create_directory",
                arguments: ["path": paths[0], "recursive": "false", "create_if_missing": "false"],
                confidence: 0.99
            )
        }
        let steps = paths.map { path in
            ResolvedPlanStep(
                toolName: "create_directory",
                arguments: ["path": path, "recursive": "false", "create_if_missing": "false"],
                description: "Create folder \((path as NSString).lastPathComponent) in \(destinationRoot)"
            )
        }
        return ResolvedIntent(
            toolName: "create_directory",
            arguments: steps[0].arguments,
            confidence: 0.99,
            planSteps: steps
        )
    }
    
    private func splitFolderNames(_ raw: String) -> [String] {
        // Normalize " and " to "," so "Backend, Frontend and Documentation" splits cleanly
        let commaJoined = raw.replacingOccurrences(of: #"\s+and\s+"#, with: ",", options: [.regularExpression, .caseInsensitive])
        return commaJoined
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " \"'.")) }
            .filter { !$0.isEmpty }
    }
    
    private func splitTrailingLocation(from text: String) -> (item: String, location: String)? {
        let pattern = #"^(.+?)\s+(?:on|in|inside|at|under|into|to|from)\s+(.+)$"#
        guard let m = firstMatchGroups(pattern: pattern, in: text), m.count >= 2 else { return nil }
        let item = m[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
        let loc = m[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
        guard !item.isEmpty && !loc.isEmpty else { return nil }
        return (item, loc)
    }
    
    private func resolveTargetWithOptionalLocation(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'."))
        if let split = splitTrailingLocation(from: trimmed), let dir = resolveKnownDirectory(from: split.location) {
            return (dir as NSString).appendingPathComponent(split.item)
        }
        return trimmed
    }
    
    private func firstMatchGroups(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else {
            return nil
        }
        var results: [String] = []
        for idx in 1..<match.numberOfRanges {
            let r = match.range(at: idx)
            if r.location != NSNotFound, let swiftRange = Range(r, in: text) {
                results.append(String(text[swiftRange]))
            } else {
                results.append("")
            }
        }
        return results
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
