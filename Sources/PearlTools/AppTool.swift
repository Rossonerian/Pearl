import AppKit
import Foundation
import PearlCore

public final class AppTool: PearlTool {
    public let name = "open_app"
    public let description = "Open or focus an application by name"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = []
    public let isReversible = true
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let appQuery = args["app"], !appQuery.isEmpty else {
            return ToolResult(success: false, message: "Missing application name.")
        }
        
        let ws = NSWorkspace.shared
        
        // Check running apps first
        if let running = ws.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(appQuery) == true
        }) {
            running.activate()
            return ToolResult(success: true, message: "Activated \(running.localizedName ?? appQuery).")
        }
        
        // Find application URL
        guard let appURL = ws.urlForApplication(withBundleIdentifier: appQuery) ??
                            ws.urlsForApplications(toOpen: URL(fileURLWithPath: "/tmp")).first(where: {
                                $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(appQuery)
                            }) ??
                            findAppURL(named: appQuery) else {
            return ToolResult(success: false, message: "Application '\(appQuery)' not found.")
        }
        
        let conf = NSWorkspace.OpenConfiguration()
        conf.activates = true
        
        do {
            let app = try await ws.openApplication(at: appURL, configuration: conf)
            let appName = app.localizedName ?? appQuery
            
            let undoAction: @Sendable () async throws -> Void = {
                DispatchQueue.main.async {
                    app.terminate()
                }
            }
            return ToolResult(success: true, message: "Opened \(appName).", undoAction: undoAction)
        } catch {
            return ToolResult(success: false, message: "Failed to open \(appQuery): \(error.localizedDescription)")
        }
    }
    
    private func findAppURL(named name: String) -> URL? {
        let candidatePaths = [
            "/Applications/\(name).app",
            "/System/Applications/\(name).app",
            "/System/Applications/Utilities/\(name).app",
            ("~" as NSString).expandingTildeInPath + "/Applications/\(name).app"
        ]
        
        for p in candidatePaths {
            if FileManager.default.fileExists(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        
        // Search in /Applications
        let fileManager = FileManager.default
        if let contents = try? fileManager.contentsOfDirectory(atPath: "/Applications") {
            for item in contents where item.hasSuffix(".app") {
                let base = (item as NSString).deletingPathExtension
                if base.localizedCaseInsensitiveContains(name) {
                    return URL(fileURLWithPath: "/Applications/\(item)")
                }
            }
        }
        return nil
    }
}

public final class CloseAppTool: PearlTool {
    public let name = "close_app"
    public let description = "Quit a running application by name"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let appQuery = args["app"], !appQuery.isEmpty else {
            return ToolResult(success: false, message: "Missing application name.")
        }
        
        let ws = NSWorkspace.shared
        guard let running = ws.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(appQuery) == true
        }) else {
            return ToolResult(success: false, message: "Application '\(appQuery)' is not running.")
        }
        
        let appName = running.localizedName ?? appQuery
        running.terminate()
        return ToolResult(success: true, message: "Closed \(appName).")
    }
}
