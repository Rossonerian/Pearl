import AppKit
import CoreGraphics
import Foundation
import PearlCore

// MARK: - ListWindowsTool

public final class ListWindowsTool: PearlTool {
    public let name = "list_windows"
    public let description = "List on-screen visible application windows with titles, owners, and frame dimensions"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = [.accessibility]
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return []
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return ToolResult(success: false, message: "Unable to retrieve visible window list from CoreGraphics.")
        }
        
        var visibleWindows: [String] = []
        
        for info in windowInfoList {
            let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? ""
            let windowTitle = (info[kCGWindowName as String] as? String) ?? ""
            let windowID = (info[kCGWindowNumber as String] as? Int) ?? 0
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            
            // Skip non-standard layers, system daemons, and invisible elements
            if layer != 0 || ownerName.isEmpty || ownerName == "Window Server" {
                continue
            }
            
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let width = boundsDict["Width"] as? Double,
                  let height = boundsDict["Height"] as? Double,
                  let x = boundsDict["X"] as? Double,
                  let y = boundsDict["Y"] as? Double,
                  width > 20 && height > 20 else {
                continue
            }
            
            let displayTitle = windowTitle.isEmpty ? "<Untitled Window>" : windowTitle
            let line = "[ID: \(windowID)] App: \(ownerName) | Title: \"\(displayTitle)\" | Frame: \(Int(width))x\(Int(height)) at (\(Int(x)), \(Int(y)))"
            visibleWindows.append(line)
        }
        
        if visibleWindows.isEmpty {
            return ToolResult(success: true, message: "No visible application windows currently open on screen.")
        }
        
        let output = "Visible Windows (\(visibleWindows.count)):\n" + visibleWindows.joined(separator: "\n")
        return ToolResult(success: true, message: output)
    }
}

// MARK: - ManageWindowTool

public final class ManageWindowTool: PearlTool {
    public let name = "manage_window"
    public let description = "Manage application window state (focus, minimize, maximize, tile_left, tile_right)"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = [.accessibility]
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "app", type: "string", description: "Target application name or bundle identifier", isRequired: true),
            ToolArgumentDescriptor(
                name: "action",
                type: "string",
                description: "Window action to perform: 'focus', 'minimize', 'maximize', 'tile_left', 'tile_right'",
                isRequired: true,
                allowedValues: ["focus", "minimize", "maximize", "tile_left", "tile_right"]
            )
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let appQuery = args["app"], !appQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ToolResult(success: false, message: "Missing required 'app' argument.")
        }
        guard let action = args["action"]?.trimmingCharacters(in: .whitespaces).lowercased(), !action.isEmpty else {
            return ToolResult(success: false, message: "Missing required 'action' argument.")
        }
        
        let ws = NSWorkspace.shared
        guard let runningApp = ws.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(appQuery) == true ||
            $0.bundleIdentifier?.localizedCaseInsensitiveContains(appQuery) == true
        }) else {
            return ToolResult(success: false, message: "Application '\(appQuery)' is not currently running.")
        }
        
        let appName = runningApp.localizedName ?? appQuery
        let safeAppName = appName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        
        switch action {
        case "focus":
            if #available(macOS 14.0, *) {
                runningApp.activate()
            } else {
                runningApp.activate(options: [.activateIgnoringOtherApps])
            }
            return ToolResult(
                success: true,
                message: "Focused front window of '\(appName)'.",
                undoAction: nil
            )
            
        case "minimize":
            let script = """
            tell application "System Events"
                tell process "\(safeAppName)"
                    if (count of windows) > 0 then
                        set miniaturized of window 1 to true
                    end if
                end tell
            end tell
            """
            return executeAppleScript(script, successMessage: "Minimized window of '\(appName)'.")
            
        case "maximize":
            let script = """
            tell application "System Events"
                tell process "\(safeAppName)"
                    if (count of windows) > 0 then
                        set value of attribute "AXFullScreen" of window 1 to true
                    end if
                end tell
            end tell
            """
            return executeAppleScript(script, successMessage: "Maximized window of '\(appName)'.")
            
        case "tile_left":
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let halfWidth = Int(screenFrame.width / 2)
            let fullHeight = Int(screenFrame.height)
            let fullScreenHeight = NSScreen.main?.frame.height ?? 900
            let topY = Int(fullScreenHeight - (screenFrame.origin.y + screenFrame.height))
            let originX = Int(screenFrame.origin.x)
            
            let script = """
            tell application "System Events"
                tell process "\(safeAppName)"
                    if (count of windows) > 0 then
                        set position of window 1 to {\(originX), \(topY)}
                        set size of window 1 to {\(halfWidth), \(fullHeight)}
                    end if
                end tell
            end tell
            """
            return executeAppleScript(script, successMessage: "Tiled window of '\(appName)' to the left half of the display.")
            
        case "tile_right":
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let halfWidth = Int(screenFrame.width / 2)
            let fullHeight = Int(screenFrame.height)
            let fullScreenHeight = NSScreen.main?.frame.height ?? 900
            let topY = Int(fullScreenHeight - (screenFrame.origin.y + screenFrame.height))
            let rightX = Int(screenFrame.origin.x) + halfWidth
            
            let script = """
            tell application "System Events"
                tell process "\(safeAppName)"
                    if (count of windows) > 0 then
                        set position of window 1 to {\(rightX), \(topY)}
                        set size of window 1 to {\(halfWidth), \(fullHeight)}
                    end if
                end tell
            end tell
            """
            return executeAppleScript(script, successMessage: "Tiled window of '\(appName)' to the right half of the display.")
            
        default:
            return ToolResult(
                success: false,
                message: "Unknown window action '\(action)'. Valid actions: focus, minimize, maximize, tile_left, tile_right."
            )
        }
    }
    
    private func executeAppleScript(_ scriptText: String, successMessage: String) -> ToolResult {
        guard let appleScript = NSAppleScript(source: scriptText) else {
            return ToolResult(success: false, message: "Failed to initialize AppleScript engine.")
        }
        
        var errorDict: NSDictionary?
        appleScript.executeAndReturnError(&errorDict)
        
        if let error = errorDict {
            let errMsg = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown System Events error"
            return ToolResult(
                success: false,
                message: "Window management failed (ensure Accessibility permission is granted): \(errMsg)"
            )
        }
        
        return ToolResult(success: true, message: successMessage)
    }
}
