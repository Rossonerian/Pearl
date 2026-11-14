import AppKit
import Foundation
import PearlCore

// MARK: - CreateMailDraftTool

public final class CreateMailDraftTool: PearlTool {
    public let name = "create_mail_draft"
    public let description = "Create a draft email message in Apple Mail without sending"
    public let tier = ToolTier.t2ReadPersonal
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "to", type: "string", description: "Recipient email address", isRequired: true),
            ToolArgumentDescriptor(name: "subject", type: "string", description: "Email subject line", isRequired: true),
            ToolArgumentDescriptor(name: "body", type: "string", description: "Email body content", isRequired: true)
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let to = args["to"]?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty else {
            return ToolResult(success: false, message: "Missing required 'to' recipient argument.")
        }
        guard let subject = args["subject"]?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty else {
            return ToolResult(success: false, message: "Missing required 'subject' argument.")
        }
        let body = args["body"] ?? ""
        
        let safeTo = to
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let safeSubject = subject
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let safeBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        
        let script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject: "\(safeSubject)", content: "\(safeBody)" & linefeed, visible: true}
            tell newMessage
                make new to recipient at end of to recipients with properties {address: "\(safeTo)"}
            end tell
            activate
        end tell
        """
        
        if let appleScript = NSAppleScript(source: script) {
            var errorDict: NSDictionary?
            appleScript.executeAndReturnError(&errorDict)
            if errorDict == nil {
                return ToolResult(success: true, message: "Draft email to '\(to)' with subject '\(subject)' created in Apple Mail.")
            }
        }
        
        // Fallback to mailto: URL if AppleScript automation is unavailable
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        
        if let mailtoURL = components.url, NSWorkspace.shared.open(mailtoURL) {
            return ToolResult(success: true, message: "Opened draft email to '\(to)' with subject '\(subject)' via default mail client.")
        }
        
        return ToolResult(success: false, message: "Could not create draft email in Apple Mail or default mail handler.")
    }
}

// MARK: - SendMailTool

public final class SendMailTool: PearlTool {
    public let name = "send_mail"
    public let description = "Send an email immediately via Apple Mail (T4 External Side Effect, requires explicit user confirmation)"
    public let tier = ToolTier.t4ExternalSideEffects
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "to", type: "string", description: "Recipient email address", isRequired: true),
            ToolArgumentDescriptor(name: "subject", type: "string", description: "Email subject line", isRequired: true),
            ToolArgumentDescriptor(name: "body", type: "string", description: "Email body content", isRequired: true)
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        // Enforce confirmation requirement for T4 external side effect
        guard context.userConfirmed else {
            return ToolResult(
                success: false,
                message: "External side effect policy refusal: Sending an email requires explicit user confirmation before execution."
            )
        }
        
        guard let to = args["to"]?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty else {
            return ToolResult(success: false, message: "Missing required 'to' recipient argument.")
        }
        guard let subject = args["subject"]?.trimmingCharacters(in: .whitespacesAndNewlines), !subject.isEmpty else {
            return ToolResult(success: false, message: "Missing required 'subject' argument.")
        }
        let body = args["body"] ?? ""
        
        let safeTo = to
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let safeSubject = subject
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let safeBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        
        let script = """
        tell application "Mail"
            set newMessage to make new outgoing message with properties {subject: "\(safeSubject)", content: "\(safeBody)" & linefeed, visible: false}
            tell newMessage
                make new to recipient at end of to recipients with properties {address: "\(safeTo)"}
            end tell
            send newMessage
        end tell
        """
        
        guard let appleScript = NSAppleScript(source: script) else {
            return ToolResult(success: false, message: "Failed to initialize AppleScript engine for Mail.")
        }
        
        var errorDict: NSDictionary?
        appleScript.executeAndReturnError(&errorDict)
        
        if let error = errorDict {
            let errorMsg = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown AppleScript error"
            return ToolResult(success: false, message: "Failed to send email via Apple Mail: \(errorMsg)")
        }
        
        return ToolResult(success: true, message: "Successfully sent email to '\(to)' with subject '\(subject)'.")
    }
}
