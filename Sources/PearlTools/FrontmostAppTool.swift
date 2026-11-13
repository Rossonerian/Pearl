import AppKit
import Foundation
import PearlCore

public final class FrontmostAppTool: PearlTool {
    public let name = "frontmost_app"
    public let description = "Get the name and bundle identifier of the currently active frontmost application"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "Finder"
        let bundleId = frontApp?.bundleIdentifier ?? "com.apple.finder"
        let msg = "Frontmost application is \(appName) (\(bundleId))."
        return ToolResult(success: true, message: msg, trust: .trusted)
    }
}
