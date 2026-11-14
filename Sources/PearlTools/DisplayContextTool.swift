import AppKit
import CoreGraphics
import Foundation
import PearlCore

/// Inspects active display configuration, refresh rates, scale factor, and color appearance.
public final class GetDisplayInfoTool: PearlTool {
    public let name = "get_display_info"
    public let description = "Inspect active display resolution, nominal refresh rate, scale factor, and color appearance"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public var argumentDescriptors: [ToolArgumentDescriptor] {
        return [
            ToolArgumentDescriptor(
                name: "detailed",
                type: "string",
                description: "Set to 'true' to include all connected displays in addition to primary",
                isRequired: false
            )
        ]
    }
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let isDetailed = args["detailed"]?.lowercased() == "true"
        
        let displaySnapshot = await MainActor.run { () -> DisplayInfoSnapshot in
            let screens = NSScreen.screens
            let primaryScreen = NSScreen.main ?? screens.first
            
            // Appearance check
            let isDarkMode: Bool
            if let appleStyle = UserDefaults.standard.string(forKey: "AppleInterfaceStyle"),
               appleStyle.caseInsensitiveCompare("Dark") == .orderedSame {
                isDarkMode = true
            } else if let mode = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication as CFString) as? String,
                      mode.caseInsensitiveCompare("Dark") == .orderedSame {
                isDarkMode = true
            } else if let app = NSApp, app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                isDarkMode = true
            } else {
                isDarkMode = false
            }
            
            var displayDescriptions: [SingleDisplayInfo] = []
            
            for (idx, screen) in screens.enumerated() {
                let displayID: CGDirectDisplayID
                if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    displayID = num.uint32Value
                } else {
                    displayID = (idx == 0) ? CGMainDisplayID() : CGDirectDisplayID(idx)
                }
                
                var rate: Double = 0.0
                if let mode = CGDisplayCopyDisplayMode(displayID) {
                    rate = mode.refreshRate
                }
                
                let scale = screen.backingScaleFactor
                let ptWidth = Int(screen.frame.width)
                let ptHeight = Int(screen.frame.height)
                let pxWidth = Int(screen.frame.width * scale)
                let pxHeight = Int(screen.frame.height * scale)
                let visWidth = Int(screen.visibleFrame.width)
                let visHeight = Int(screen.visibleFrame.height)
                let isMain = (screen == primaryScreen)
                let name = screen.localizedName
                
                displayDescriptions.append(SingleDisplayInfo(
                    index: idx,
                    name: name,
                    isMain: isMain,
                    displayID: displayID,
                    pointResolution: "\(ptWidth)x\(ptHeight)",
                    pixelResolution: "\(pxWidth)x\(pxHeight)",
                    visibleResolution: "\(visWidth)x\(visHeight)",
                    scaleFactor: scale,
                    refreshRate: rate
                ))
            }
            
            return DisplayInfoSnapshot(
                isDarkMode: isDarkMode,
                totalDisplays: screens.count,
                displays: displayDescriptions
            )
        }
        
        let primary = displaySnapshot.displays.first(where: { $0.isMain }) ?? displaySnapshot.displays.first
        
        guard let mainDisplay = primary else {
            return ToolResult(
                success: true,
                message: "Display Info: No active display detected (headless environment). Appearance: \(displaySnapshot.appearanceString)."
            )
        }
        
        // Refresh rate formatting
        let refreshStr: String
        if mainDisplay.refreshRate > 0.0 {
            refreshStr = "\(Int(mainDisplay.refreshRate)) Hz"
        } else {
            refreshStr = "60 Hz (MacBook Neo nominal target)"
        }
        
        var summary = """
        Display Context:
        • Active Resolution: \(mainDisplay.pointResolution) pt (\(mainDisplay.pixelResolution) px)
        • Scale Factor: \(String(format: "%.1f", mainDisplay.scaleFactor))x (\(mainDisplay.scaleFactor >= 2.0 ? "Retina / HiDPI" : "Standard"))
        • Nominal Refresh Rate: \(refreshStr)
        • Appearance: \(displaySnapshot.appearanceString)
        • Display Name: \(mainDisplay.name)
        • Connected Displays: \(displaySnapshot.totalDisplays)
        """
        
        if isDetailed && displaySnapshot.displays.count > 1 {
            summary += "\n\nAll Displays:"
            for d in displaySnapshot.displays {
                let dRefresh = d.refreshRate > 0 ? "\(Int(d.refreshRate)) Hz" : "60 Hz"
                summary += "\n  Display #\(d.index + 1) [\(d.isMain ? "Primary" : "Secondary")]: \(d.name) - \(d.pointResolution) pt @ \(d.scaleFactor)x (\(dRefresh))"
            }
        }
        
        return ToolResult(success: true, message: summary)
    }
}

// MARK: - Internal Display Data Structures

fileprivate struct SingleDisplayInfo: Sendable {
    let index: Int
    let name: String
    let isMain: Bool
    let displayID: CGDirectDisplayID
    let pointResolution: String
    let pixelResolution: String
    let visibleResolution: String
    let scaleFactor: CGFloat
    let refreshRate: Double
}

fileprivate struct DisplayInfoSnapshot: Sendable {
    let isDarkMode: Bool
    let totalDisplays: Int
    let displays: [SingleDisplayInfo]
    
    var appearanceString: String {
        return isDarkMode ? "Dark Mode" : "Light Mode"
    }
}

// MARK: - Alias for Discovery and Central Catalog

public final class DisplayContextTool: PearlTool {
    public let name = "display_info"
    public let description = "Query macOS display specifications, resolution, scaling, and system appearance"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    private let innerTool = GetDisplayInfoTool()
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        return try await innerTool.execute(args: args, context: context)
    }
}
