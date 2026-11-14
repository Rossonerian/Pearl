import AVFoundation
import Foundation

/// Audio capture engine facade delegating directly to the unified `AudioPipelineService`.
///
/// Prevents duplicated `AVAudioEngine` instances and shares the single input tap
/// with live speech recognition and RMS waveform metering.
public final class AudioCaptureEngine: NSObject, @unchecked Sendable {
    public static let shared = AudioCaptureEngine()
    
    private let pipeline = AudioPipelineService.shared
    
    public var onAudioBufferReceived: (([Float]) -> Void)? {
        get { pipeline.onAudioBufferReceived }
        set { pipeline.onAudioBufferReceived = newValue }
    }
    
    public var onLevelMeterUpdated: ((Float) -> Void)? {
        get { pipeline.onLevelMeterUpdated }
        set { pipeline.onLevelMeterUpdated = newValue }
    }
    
    public override init() {
        super.init()
    }
    
    public func startCapture() throws {
        try pipeline.startCapture()
    }
    
    public func stopCapture() {
        pipeline.stopCapture()
    }
    
    public func enterStandby() {
        pipeline.enterStandby()
    }
    
    public var active: Bool {
        return pipeline.isCaptureEnabled
    }
}
