import Foundation
import IOKit.ps
import PearlCore

public final class BatteryTool: PearlTool {
    public let name = "battery"
    public let description = "Get current battery percentage and charging status"
    public let tier = ToolTier.t0Observe
    public let requiredTCC: [TCCService] = []
    public let isReversible = false
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return ToolResult(success: false, message: "Could not read battery state from IOKit")
        }
        
        for ps in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            
            let curCap = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
            let powerSourceState = desc[kIOPSPowerSourceStateKey as String] as? String ?? ""
            let isAC = powerSourceState == (kIOPSACPowerValue as String)
            
            let status = isCharging ? "charging" : (isAC ? "plugged in, not charging" : "on battery")
            let msg = "Battery is at \(curCap)% (\(status))."
            return ToolResult(success: true, message: msg)
        }
        
        return ToolResult(success: true, message: "No battery detected (desktop Mac).")
    }
}
