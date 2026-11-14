import AppKit
import Foundation
import PearlCore

// MARK: - Secret Redactor Utility

public final class SecretRedactor: Sendable {
    public static let shared = SecretRedactor()
    
    public struct RedactionResult: Sendable {
        public let text: String
        public let redactionCount: Int
    }
    
    private struct PatternDefinition: Sendable {
        let regex: NSRegularExpression
        let template: String
    }
    
    private let patterns: [PatternDefinition]
    
    public init() {
        var list: [PatternDefinition] = []
        
        // 1. PEM Private Keys & Certificates
        let pemRegex = #"(?s)-----BEGIN [A-Z0-9_\- ]*PRIVATE KEY-----.*?-----END [A-Z0-9_\- ]*PRIVATE KEY-----"#
        if let r = try? NSRegularExpression(pattern: pemRegex, options: []) {
            list.append(PatternDefinition(regex: r, template: "[REDACTED_PRIVATE_KEY]"))
        }
        let certRegex = #"(?s)-----BEGIN [A-Z0-9_\- ]*CERTIFICATE-----.*?-----END [A-Z0-9_\- ]*CERTIFICATE-----"#
        if let r = try? NSRegularExpression(pattern: certRegex, options: []) {
            list.append(PatternDefinition(regex: r, template: "[REDACTED_CERTIFICATE]"))
        }
        
        // 2. Bearer Authentication Tokens
        let bearerRegex = #"(?i)\b(bearer\s+)([A-Za-z0-9_\-\.~+/]+=*)"#
        if let r = try? NSRegularExpression(pattern: bearerRegex, options: []) {
            list.append(PatternDefinition(regex: r, template: "$1[REDACTED_BEARER_TOKEN]"))
        }
        
        // 3. Provider Specific Keys
        // GitHub
        if let r = try? NSRegularExpression(pattern: #"\bgh[pousr]_[A-Za-z0-9_]{30,}\b"#, options: []) {
            list.append(PatternDefinition(regex: r, template: "[REDACTED_GITHUB_TOKEN]"))
        }
        // AWS Access Key ID
        if let r = try? NSRegularExpression(pattern: #"\b(AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b"#, options: []) {
            list.append(PatternDefinition(regex: r, template: "$1[REDACTED_AWS_KEY]"))
        }
        // AWS Secret Key
        if let r = try? NSRegularExpression(pattern: #"(?i)(aws_secret_access_key\s*[:=]\s*['"]?)[A-Za-z0-9/+=]{40}['"]?"#, options: []) {
            list.append(PatternDefinition(regex: r, template: "$1[REDACTED_AWS_SECRET]"))
        }
        // Anthropic Key
        if let r = try? NSRegularExpression(pattern: #"\bsk-ant-[a-zA-Z0-9_\-]{20,}\b"#, options: []) {
            list.append(PatternDefinition(regex: r, template: "[REDACTED_ANTHROPIC_KEY]"))
        }
        // OpenAI Key
        if let r = try? NSRegularExpression(pattern: #"\bsk-(?:proj-|live-)?[a-zA-Z0-9_\-]{20,}\b"#, options: []) {
            list.append(PatternDefinition(regex: r, template: "[REDACTED_OPENAI_KEY]"))
        }
        // Slack Token
        if let r = try? NSRegularExpression(pattern: #"\bxox[baprs]-[0-9a-zA-Z]{10,}\b"#, options: []) {
            list.append(PatternDefinition(regex: r, template: "[REDACTED_SLACK_TOKEN]"))
        }
        // JWT Token (eyJ...)
        if let r = try? NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#, options: []) {
            list.append(PatternDefinition(regex: r, template: "[REDACTED_JWT]"))
        }
        
        // 4. Generic credential assignments (e.g. password=..., api_key="...")
        let genericSecretRegex = #"(?i)\b(password|passwd|api_key|apikey|secret|access_token|auth_token|client_secret)(\s*[:=]\s*['"]?)([^\s'"]{8,})(['"]?)"#
        if let r = try? NSRegularExpression(pattern: genericSecretRegex, options: []) {
            list.append(PatternDefinition(regex: r, template: "$1$2[REDACTED_SECRET]$4"))
        }
        
        self.patterns = list
    }
    
    public func redact(text: String) -> RedactionResult {
        var currentText = text
        var totalCount = 0
        
        for pat in patterns {
            let matches = pat.regex.matches(in: currentText, options: [], range: NSRange(location: 0, length: currentText.utf16.count))
            if !matches.isEmpty {
                totalCount += matches.count
                currentText = pat.regex.stringByReplacingMatches(
                    in: currentText,
                    options: [],
                    range: NSRange(location: 0, length: currentText.utf16.count),
                    withTemplate: pat.template
                )
            }
        }
        
        return RedactionResult(text: currentText, redactionCount: totalCount)
    }
}

// MARK: - Tool 1: read_clipboard (Tier T0 Observe)

public final class ReadClipboardTool: PearlTool {
    public let name = "read_clipboard"
    public let description = "Read text from the macOS system clipboard with automatic secret redaction"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "max_length",
                type: "string",
                description: "Maximum number of characters to return (defaults to 2000)",
                isRequired: false
            )
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let maxChars = Int(args["max_length"] ?? "2000") ?? 2000
        
        let rawContent = await MainActor.run { () -> String? in
            return NSPasteboard.general.string(forType: .string)
        }
        
        guard let text = rawContent, !text.isEmpty else {
            return ToolResult(success: true, message: "Clipboard is empty.")
        }
        
        let redaction = SecretRedactor.shared.redact(text: text)
        var outputText = redaction.text
        let truncated: Bool
        if outputText.count > maxChars {
            outputText = String(outputText.prefix(maxChars)) + "\n... [truncated]"
            truncated = true
        } else {
            truncated = false
        }
        
        var summary = "Clipboard Content (\(text.count) characters"
        if redaction.redactionCount > 0 {
            summary += ", \(redaction.redactionCount) secret(s) redacted"
        }
        if truncated {
            summary += ", preview truncated to \(maxChars) chars"
        }
        summary += "):\n\n\(outputText)"
        
        return ToolResult(success: true, message: summary)
    }
}

// MARK: - Tool 2: write_clipboard (Tier T1 Reversible)

public final class WriteClipboardTool: PearlTool {
    public let name = "write_clipboard"
    public let description = "Write text to the macOS system clipboard, saving previous content to UndoJournal"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = []
    public let isReversible = true
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "text",
                type: "string",
                description: "Text content to copy to the clipboard",
                isRequired: true
            )
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let textToCopy = args["text"] ?? args["content"] ?? args["value"], !textToCopy.isEmpty else {
            return ToolResult(success: false, message: "Missing required 'text' to write to clipboard.")
        }
        
        let previousContent = await MainActor.run { () -> String in
            let old = NSPasteboard.general.string(forType: .string) ?? ""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(textToCopy, forType: .string)
            return old
        }
        
        let undoAction: @Sendable () async throws -> Void = {
            await MainActor.run {
                NSPasteboard.general.clearContents()
                if !previousContent.isEmpty {
                    NSPasteboard.general.setString(previousContent, forType: .string)
                }
            }
        }
        
        // Register with UndoJournal
        await UndoJournal.shared.register(toolName: "write_clipboard", undoAction: undoAction)
        
        let charCount = textToCopy.count
        let lineCount = textToCopy.components(separatedBy: .newlines).count
        return ToolResult(
            success: true,
            message: "Copied \(charCount) character(s) (\(lineCount) line(s)) to clipboard.",
            undoAction: undoAction
        )
    }
}

// MARK: - Unified Clipboard Router

public final class ClipboardTool: PearlTool {
    public let name = "clipboard"
    public let description = "Read or write macOS clipboard with secret redaction and undo support"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = []
    public let isReversible = true
    
    private let readTool = ReadClipboardTool()
    private let writeTool = WriteClipboardTool()
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let action = args["action"]?.lowercased() ?? (args["text"] != nil ? "write" : "read")
        if action == "write" || action == "copy" || action == "set" {
            return try await writeTool.execute(args: args, context: context)
        } else {
            return try await readTool.execute(args: args, context: context)
        }
    }
}
