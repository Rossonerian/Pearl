import AudioToolbox
import CoreAudio
import Foundation
import PearlCore

public final class VolumeTool: PearlTool {
    public let name = "volume"
    public let description = "Set, get, or mute output audio volume"
    public let tier = ToolTier.t1Reversible
    public let requiredTCC: [TCCService] = []
    public let isReversible = true
    
    public init() {}
    
    public func execute(args: [String: String], context: ToolExecutionContext) async throws -> ToolResult {
        let currentVol = getVolume()
        
        guard let levelStr = args["level"], let targetInt = Int(levelStr) else {
            return ToolResult(success: true, message: "Current volume is \(Int(currentVol * 100))%.")
        }
        
        let clampedInt = max(0, min(100, targetInt))
        let targetFloat = Float(clampedInt) / 100.0
        setVolume(targetFloat)
        
        let previousLevel = currentVol
        let undoAction: @Sendable () async throws -> Void = {
            VolumeTool.setVolumeStatic(previousLevel)
        }
        
        let msg = clampedInt == 0 ? "Volume muted (0%)." : "Volume set to \(clampedInt)%."
        return ToolResult(success: true, message: msg, undoAction: undoAction)
    }
    
    public func getVolume() -> Float {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID
        ) == noErr else {
            return 0.5
        }
        
        var volume = Float32(0.0)
        propertySize = UInt32(MemoryLayout<Float32>.size)
        propertyAddress.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        propertyAddress.mScope = kAudioDevicePropertyScopeOutput
        propertyAddress.mElement = kAudioObjectPropertyElementMain
        
        let status = AudioObjectGetPropertyData(
            defaultOutputDeviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &volume
        )
        
        return status == noErr ? volume : 0.5
    }
    
    public func setVolume(_ volume: Float) {
        VolumeTool.setVolumeStatic(volume)
    }
    
    public static func setVolumeStatic(_ volume: Float) {
        var defaultOutputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultOutputDeviceID
        ) == noErr else {
            return
        }
        
        var vol = volume
        propertySize = UInt32(MemoryLayout<Float32>.size)
        propertyAddress.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        propertyAddress.mScope = kAudioDevicePropertyScopeOutput
        propertyAddress.mElement = kAudioObjectPropertyElementMain
        
        _ = AudioObjectSetPropertyData(
            defaultOutputDeviceID,
            &propertyAddress,
            0,
            nil,
            propertySize,
            &vol
        )
    }
}
