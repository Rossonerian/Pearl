import AppKit
import Foundation
import PearlCore
import UserNotifications

/// Posts a native macOS system notification using UserNotifications framework,
/// with reliable fallback to NSUserNotification and osascript for unbundled/CLI environments.
public final class PostNotificationTool: PearlTool {
    public let name = "post_notification"
    public let description = "Post a native macOS user notification with title, subtitle, message, and sound"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "title",
                type: "string",
                description: "Notification title (defaults to 'Pearl')",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "message",
                type: "string",
                description: "Main notification body message text",
                isRequired: true
            ),
            ToolArgumentDescriptor(
                name: "subtitle",
                type: "string",
                description: "Optional subtitle text",
                isRequired: false
            ),
            ToolArgumentDescriptor(
                name: "sound",
                type: "string",
                description: "Whether to play notification sound ('default' or 'true')",
                isRequired: false
            )
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let message = args["message"] ?? args["body"] ?? args["text"], !message.isEmpty else {
            return ToolResult(success: false, message: "Missing required 'message' for notification.")
        }
        
        let title = args["title"] ?? "Pearl"
        let subtitle = args["subtitle"]
        let playSound = args["sound"]?.lowercased() == "true" || args["sound"]?.lowercased() == "default"
        
        var postedVia = "UserNotifications"
        var deliverySuccess = false
        
        // 1. Attempt UserNotifications framework if bundle identifier exists
        if Bundle.main.bundleIdentifier != nil {
            deliverySuccess = await postViaUNNotification(
                title: title,
                subtitle: subtitle,
                message: message,
                playSound: playSound
            )
        }
        
        // 2. Fallback to NSUserNotificationCenter if UNNotificationCenter failed or unbundled
        if !deliverySuccess {
            deliverySuccess = await postViaLegacyNotificationCenter(
                title: title,
                subtitle: subtitle,
                message: message,
                playSound: playSound
            )
            if deliverySuccess {
                postedVia = "NSUserNotificationCenter"
            }
        }
        
        // 3. Fallback to AppleScript display notification if running in pure CLI/daemon mode
        if !deliverySuccess {
            deliverySuccess = await postViaAppleScript(
                title: title,
                subtitle: subtitle,
                message: message,
                playSound: playSound
            )
            if deliverySuccess {
                postedVia = "System Script"
            }
        }
        
        if deliverySuccess {
            return ToolResult(
                success: true,
                message: "Notification posted via \(postedVia): '\(title)' – \(message)"
            )
        } else {
            return ToolResult(
                success: false,
                message: "Failed to post notification to macOS Notification Center."
            )
        }
    }
    
    private func postViaUNNotification(
        title: String,
        subtitle: String?,
        message: String,
        playSound: Bool
    ) async -> Bool {
        let center = UNUserNotificationCenter.current()
        
        let authorized = await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        
        guard authorized else { return false }
        
        let content = UNMutableNotificationContent()
        content.title = title
        if let sub = subtitle, !sub.isEmpty {
            content.subtitle = sub
        }
        content.body = message
        if playSound {
            content.sound = UNNotificationSound.default
        }
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
    
    private func postViaLegacyNotificationCenter(
        title: String,
        subtitle: String?,
        message: String,
        playSound: Bool
    ) async -> Bool {
        return await MainActor.run {
            guard let centerClass = NSClassFromString("NSUserNotificationCenter") as? NSObject.Type,
                  let center = centerClass.perform(NSSelectorFromString("defaultUserNotificationCenter"))?.takeUnretainedValue(),
                  let notificationClass = NSClassFromString("NSUserNotification") as? NSObject.Type else {
                return false
            }
            let notification = notificationClass.init()
            notification.setValue(title, forKey: "title")
            if let sub = subtitle, !sub.isEmpty {
                notification.setValue(sub, forKey: "subtitle")
            }
            notification.setValue(message, forKey: "informativeText")
            if playSound {
                notification.setValue("NSUserNotificationDefaultSoundName", forKey: "soundName")
            }
            _ = center.perform(NSSelectorFromString("deliverNotification:"), with: notification)
            return true
        }
    }
    
    private func postViaAppleScript(
        title: String,
        subtitle: String?,
        message: String,
        playSound: Bool
    ) async -> Bool {
        return await Task.detached {
            let escapedMsg = message.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
            var script = "display notification \"\(escapedMsg)\" with title \"\(escapedTitle)\""
            if let sub = subtitle, !sub.isEmpty {
                let escapedSub = sub.replacingOccurrences(of: "\"", with: "\\\"")
                script += " subtitle \"\(escapedSub)\""
            }
            if playSound {
                script += " sound name \"default\""
            }
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
}

// MARK: - Alias for Unified Notification Tool

public final class NotificationTool: PearlTool {
    public let name = "notification"
    public let description = "Send native macOS user notifications"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    private let inner = PostNotificationTool()
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        return try await inner.execute(args: args, context: context)
    }
}
