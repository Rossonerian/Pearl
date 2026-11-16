import AppKit
import Foundation
import PearlCore

// MARK: - ListBrowserTabsTool

public final class ListBrowserTabsTool: PearlTool {
    public let name = "list_browser_tabs"
    public let description = "List open tabs (title and URL) from running Safari and Google Chrome browsers"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return []
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let ws = NSWorkspace.shared
        let running = ws.runningApplications
        let isSafariRunning = running.contains { $0.bundleIdentifier == "com.apple.Safari" }
        let isChromeRunning = running.contains { $0.bundleIdentifier == "com.google.Chrome" }
        
        guard isSafariRunning || isChromeRunning else {
            return ToolResult(success: true, message: "No supported browsers (Safari or Chrome) are currently running.")
        }
        
        var allTabs: [String] = []
        
        if isSafariRunning {
            let script = """
            tell application "Safari"
                set tabList to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        set end of tabList to ("[Safari] " & name of t & " | " & URL of t)
                    end repeat
                end repeat
                return tabList
            end tell
            """
            allTabs.append(contentsOf: runAppleScriptList(script))
        }
        
        if isChromeRunning {
            let script = """
            tell application "Google Chrome"
                set tabList to {}
                repeat with w in windows
                    repeat with t in tabs of w
                        set end of tabList to ("[Chrome] " & title of t & " | " & URL of t)
                    end repeat
                end repeat
                return tabList
            end tell
            """
            allTabs.append(contentsOf: runAppleScriptList(script))
        }
        
        if allTabs.isEmpty {
            return ToolResult(success: true, message: "No open browser tabs found.")
        }
        
        let output = "Open Browser Tabs (\(allTabs.count)):\n" + allTabs.joined(separator: "\n")
        return ToolResult(success: true, message: output)
    }
    
    private func runAppleScriptList(_ scriptText: String) -> [String] {
        guard let script = NSAppleScript(source: scriptText) else { return [] }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        guard error == nil else { return [] }
        
        var list: [String] = []
        let count = descriptor.numberOfItems
        if count > 0 {
            for i in 1...count {
                if let item = descriptor.atIndex(i)?.stringValue, !item.trimmingCharacters(in: .whitespaces).isEmpty {
                    list.append(item)
                }
            }
        } else if let single = descriptor.stringValue, !single.isEmpty {
            list.append(single)
        }
        return list
    }
}

// MARK: - OpenURLTool

public final class OpenURLTool: PearlTool {
    public let name = "open_url"
    public let description = "Open an HTTP or HTTPS URL in the default web browser"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(name: "url", type: "string", description: "The web URL to open (must be http:// or https://)", isRequired: true)
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let rawURL = args["url"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty else {
            return ToolResult(success: false, message: "Missing required 'url' argument.")
        }
        
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return ToolResult(
                success: false,
                message: "URL blocked by security policy: Only http:// and https:// URLs are permitted. Schemes such as javascript:, file:, data:, and ftp: are forbidden."
            )
        }
        
        let opened = NSWorkspace.shared.open(url)
        if opened {
            return ToolResult(
                success: true,
                message: "Opened URL in default browser: \(url.absoluteString)",
                undoAction: nil
            )
        } else {
            return ToolResult(success: false, message: "Failed to open URL in browser: \(url.absoluteString)")
        }
    }
}

// MARK: - ReadActiveTabTool

public final class ReadActiveTabTool: PearlTool {
    public let name = "read_active_tab"
    public let description = "Read the title and URL of the frontmost browser tab in Safari or Chrome"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return []
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let ws = NSWorkspace.shared
        let running = ws.runningApplications
        
        let frontmost = ws.frontmostApplication?.bundleIdentifier
        let isFrontChrome = frontmost == "com.google.Chrome"
        
        let isSafariRunning = running.contains { $0.bundleIdentifier == "com.apple.Safari" }
        let isChromeRunning = running.contains { $0.bundleIdentifier == "com.google.Chrome" }
        
        guard isSafariRunning || isChromeRunning else {
            return ToolResult(
                success: false,
                message: "Neither Safari nor Google Chrome is currently running.",
                trust: .untrusted
            )
        }
        
        var tabInfo: String?
        
        // Check frontmost first, then fallback
        if isFrontChrome || (!isSafariRunning && isChromeRunning) {
            tabInfo = readChromeActiveTab()
        } else {
            tabInfo = readSafariActiveTab()
            if tabInfo == nil && isChromeRunning {
                tabInfo = readChromeActiveTab()
            }
        }
        
        guard let content = tabInfo, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolResult(
                success: false,
                message: "Could not read active browser tab (no windows or tabs open).",
                trust: .untrusted
            )
        }
        
        // Explicitly mark context as tainted due to ingestion of external web content
        TaintTracker.shared.markTainted(
            source: "browser_tab",
            reason: "Read active tab content: \(content.prefix(100))"
        )
        
        return ToolResult(
            success: true,
            message: content,
            trust: .untrusted
        )
    }
    
    private func readSafariActiveTab() -> String? {
        let script = """
        tell application "Safari"
            if (count of windows) > 0 then
                set currentTab to current tab of front window
                return ("Title: " & name of currentTab & "\nURL: " & URL of currentTab)
            end if
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let res = appleScript.executeAndReturnError(&error)
        return error == nil ? res.stringValue : nil
    }
    
    private func readChromeActiveTab() -> String? {
        let script = """
        tell application "Google Chrome"
            if (count of windows) > 0 then
                set currentTab to active tab of front window
                return ("Title: " & title of currentTab & "\nURL: " & URL of currentTab)
            end if
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let res = appleScript.executeAndReturnError(&error)
        return error == nil ? res.stringValue : nil
    }
}
